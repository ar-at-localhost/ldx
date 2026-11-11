# `ldx`: one tool — a CLI that tracks and manages nvim LSP library deps.
#
# Single module, single flake output (`.#ldx`): the CLI binary, with the locked
# per-project resolutions it needs attached as `deps` (`nix build .#ldx.deps.<project>`).
# `ldx sync` resolves each `.ldx.json` manifest against the repo's pinned pkgs by
# building the matching `deps` derivation; its out-link GC-protects every library.
#
# NOTE: `local` refs (any relative path such as `./x`, `../x/y/z`) are deliberately
# NOT resolved in Nix. Inside a flake, paths are copied to the store, so resolving
# them here would yield /nix/store paths. They are passed through verbatim and
# resolved by `ldx sync` against the real, live project directory.
{pkgs, ...}: let
  versionInfo = import ./version.nix;
  inherit (versionInfo) version;
  inherit (builtins) readDir pathExists readFile fromJSON toJSON toString;
  inherit (pkgs) lib;
  lapsDir = toString ../.;

  # `vimPlugins.snacks-nvim` -> `VIMPLUGINS_SNACKS_NVIM` (mirrors legacy ldx env naming)
  sanitize = s: let
    chars = lib.stringToCharacters s;
    ok = c:
      if builtins.match "[A-Za-z0-9]" c != null
      then c
      else "_";
  in
    lib.toUpper (lib.concatStrings (map ok chars));

  pkgByPath = attr: lib.getAttrFromPath (lib.splitString "." attr) pkgs;

  # One manifest ref -> a dependency entry. `kind` is one of:
  #   nix      -> `path` is a store path, `subdir` points at the lua library dir
  #   local    -> `path` is the RELATIVE ref, untouched (resolved by `ldx sync`
  #               against the real project dir, so it is never a store path)
  #   literal  -> `path` is used verbatim (`${3rd}/luv/library`)
  resolveRef = _dir: ref:
    if lib.hasPrefix "./" ref || lib.hasPrefix "../" ref
    then {
      kind = "local";
      var = "LDX_LOCAL_${sanitize ref}";
      name = sanitize ref;
      path = ref;
    }
    else if ref == "luv"
    then {
      kind = "literal";
      var = "LDX_LUV_LIBRARY";
      name = "luv";
      path = "\${3rd}/luv/library";
    }
    else if ref == "vim"
    then {
      kind = "nix";
      var = "LDX_VIM_RUNTIME";
      name = "nvim";
      path = pkgs.neovim-unwrapped;
      subdir = "share/nvim/runtime/lua";
    }
    else let
      parts = lib.splitString ":" ref;
      flake =
        if builtins.length parts >= 2
        then builtins.elemAt parts 0
        else "nixpkgs";
      attr =
        if builtins.length parts == 1
        then builtins.elemAt parts 0
        else builtins.elemAt parts 1;
      subdir =
        if builtins.length parts == 3
        then builtins.elemAt parts 2
        else "lua";

      package =
        if flake == "nixpkgs" || flake == "."
        then pkgByPath attr
        else throw "ldx: unsupported flake '${flake}' in ref '${ref}' (${toString _dir})";
    in {
      kind = "nix";
      var = "LDX_${sanitize attr}";
      name = sanitize attr;
      inherit subdir;
      path = package;
    };

  projectDeps = _name: dir:
    map (resolveRef dir) (fromJSON (readFile (dir + "/.ldx.json")));

  projects =
    lib.filterAttrs
    (name: type: type == "directory" && pathExists (lapsDir + "/" + name + "/.ldx.json"))
    (readDir lapsDir);

  deps = lib.mapAttrs (name: _: let
    dir = lapsDir + "/" + name;
    projectDeps' = projectDeps name dir;
  in
    pkgs.runCommand "ldx-deps-${name}" {} ''
      mkdir -p $out
      echo '${toJSON projectDeps'}' > $out/deps.json
    '')
  projects;

  repoFlag = {
    name = "repo";
    description = "Path to the arnos repository (default: \$ARNOS_REPO or ~/workspaces/arnos)";
  };

  prelude = ''
    _ldx_repo() {
      local r
      r="''${repo:-''${ARNOS_REPO:-''${HOME}/workspaces/arnos}}"
      r="$({ cd "$r" 2>/dev/null && pwd; } || echo "$r")"
      if [[ ! -f "$r/flake.lock" ]]; then
        echo "ldx: error: could not find arnos repo at '$r'" >&2
        exit 1
      fi
      echo "$r"
    }

    # projects: names/dirs given as args, or every dir under apps holding a manifest
    _ldx_projects() {
      local laps_dir="$1"
      shift
      local dirs=()
      if [[ $# -gt 0 ]]; then
        local p d
        for p in "$@"; do
          if [[ -d "$p" ]]; then d="$p"; else d="$laps_dir/$p"; fi
          if [[ ! -f "$d/.ldx.json" ]]; then
            echo "ldx: error: no manifest at $d/.ldx.json" >&2
            return 1
          fi
          dirs+=("$d")
        done
      else
        # glob avoids relying on find's -mindepth/-maxdepth behaviour
        local p
        for p in "$laps_dir"/*/.ldx.json; do
          [[ -e "$p" ]] || continue
          dirs+=("''${p%/.ldx.json}")
        done
      fi
      if [[ ''${#dirs[@]} -gt 0 ]]; then
        printf '%s\n' "''${dirs[@]}"
      fi
    }

    _contains() {
      local needle="$1"
      shift
      local x
      for x in "$@"; do
        [[ "$x" == "$needle" ]] && return 0
      done
      return 1
    }

    # cheap change detection: manifest + repo lockfile are the only facts that
    # can alter resolution, hashing them costs no nix invocations at all
    _ldx_fingerprint() {
      local d="$1" lock="$2"
      # "rev2" salt: bump whenever resolution semantics change, so stale state
      # (e.g. local deps recorded as /nix/store paths) is re-resolved
      { echo "ldx-state-rev2"; cat "$d/.ldx.json"; cat "$lock"; } | sha256sum | cut -d' ' -f1
    }

    # lightweight validation of a previously sync'ed state: every non-literal
    # reference must still resolve to a real directory (no nix involved)
    _ldx_lightcheck() {
      local st="$1" kind value real bad=0
      [[ -f "$st" ]] || return 1
      while IFS=$'\t' read -r kind value; do
        [[ "$kind" == "literal" ]] && continue
        # a local dep must be a live working-tree path, never a store copy
        if [[ "$kind" == "local" && "$value" == /nix/store/* ]]; then
          bad=1
          continue
        fi
        real="$(realpath "$value" 2>/dev/null || true)"
        if [[ -z "$real" || ! -d "$real" ]]; then
          bad=1
        fi
      done < <(jq -r '.deps[] | [.kind, (.value // "")] | @tsv' "$st")
      return $bad
    }
  '';

  cli = pkgs.pog.pog {
    name = "ldx";
    description = "Lua dependency manager: resolves nvim LSP library references (.luarc.json)";
    inherit version;

    runtimeInputs = [pkgs.jq pkgs.findutils pkgs.gnused pkgs.coreutils];

    commands = [
      {
        name = "sync";
        description = "Resolve dependencies and update .luarc.json for projects (default: all)";
        flags = [repoFlag];
        arguments = [
          {
            name = "projects";
            description = "Project dirs/names (default: all)";
            variadic = true;
          }
        ];
        script = ''
          ${prelude}

          sync_project() {
            local d="$1" lock="$2"
            local proj ldx_dir fp stored st deps_out json
            proj="$(basename "$d")"
            ldx_dir="$d/.ldx"
            st="$ldx_dir/state.json"

            mkdir -p "$ldx_dir/lib" "$ldx_dir/gcroots" || return 1

            fp="$(_ldx_fingerprint "$d" "$lock")"
            stored="$(jq -r '.fingerprint // ""' "$st" 2>/dev/null || true)"

            # fast path: nothing about resolution changed and references still
            # exist, so avoid every nix operation
            if [[ "$fp" == "$stored" ]] && _ldx_lightcheck "$st"; then
              echo "ldx: $proj: up to date"
              return 0
            fi

            echo "ldx: $proj: resolving dependencies..."
            # one build per changed project; its closure protects every
            # dependency from the garbage collector via the `deps` out-link
            deps_out="$(nix build "''${repo_}#ldx.deps.''${proj}" --out-link "$ldx_dir/gcroots/deps" --print-out-paths 2>"$ldx_dir/sync.err")" || true
            if [[ -z "$deps_out" || ! -f "$deps_out/deps.json" ]]; then
              echo "ldx: error: $proj: dependency resolution failed:" >&2
              sed 's/^/ldx:   /' "$ldx_dir/sync.err" >&2 2>/dev/null || true
              rm -f "$ldx_dir/sync.err"
              return 1
            fi
            rm -f "$ldx_dir/sync.err"
            json="$(cat "$deps_out/deps.json")"

            local line kind var name path subdir value realp abs tmp existing
            local -a deps_json=() paths=() names=()

            while IFS= read -r line; do
              [[ -n "$line" ]] || continue
              kind="$(jq -r '.kind' <<< "$line")"
              var="$(jq -r '.var' <<< "$line")"
              name="$(jq -r '.name // ""' <<< "$line")"
              path="$(jq -r '.path // ""' <<< "$line")"
              subdir="$(jq -r '.subdir // ""' <<< "$line")"
              value=""

              case "$kind" in
                nix)
                  if [[ ! -d "$path" || -z "$subdir" || ! -d "$path/$subdir" ]]; then
                    echo "ldx: error: $proj: $var: missing library dir at $path/$subdir" >&2
                    return 1
                  fi
                  ln -sfn "$path/$subdir" "$ldx_dir/lib/$name"
                  value="$ldx_dir/lib/$name"
                  names+=("$name")
                  ;;
                local)
                  # `path` is the raw relative ref from the manifest (./x, ../x/y/z, ...).
                  # Resolve it against the REAL project dir ($d, a live checkout),
                  # never against the nix store.
                  case "$path" in
                    /*) abs="$path" ;;
                    *)  abs="$d/$path" ;;
                  esac
                  realp="$(realpath -m "$abs" 2>/dev/null || true)"
                  if [[ -z "$realp" || ! -d "$realp" ]]; then
                    echo "ldx: error: $proj: $var: local dependency not found at $abs" >&2
                    return 1
                  fi
                  value="$realp"
                  ;;
                literal)
                  value="$path"
                  ;;
                *)
                  echo "ldx: error: $proj: unknown kind '$kind' for $var" >&2
                  return 1
                  ;;
              esac

              paths+=("\''${env:''${var}}")
              deps_json+=("$(jq -nc --arg var "$var" --arg kind "$kind" --arg name "$name" --arg value "$value" --arg path "$path" --arg subdir "$subdir" '{var: $var, kind: $kind, name: $name, value: $value, path: $path, subdir: $subdir}')")
            done < <(jq -c '.[]' <<< "$json")

            local deps_json_s paths_json
            if [[ ''${#deps_json[@]} -eq 0 ]]; then
              deps_json_s="[]"
            else
              deps_json_s="$(printf '%s\n' "''${deps_json[@]}" | jq -s .)"
            fi
            echo "$deps_json_s" | jq --arg project "$proj" --arg fingerprint "$fp" '{project: $project, fingerprint: $fingerprint, deps: .}' > "$st"

            # prune stale lib links that are no longer in the manifest
            for f in "$ldx_dir"/lib/*; do
              [[ -e "$f" || -L "$f" ]] || continue
              b="$(basename "$f")"
              if ! _contains "$b" "''${names[@]}"; then
                rm -f "$f"
              fi
            done
            # the only project-level root is `deps` now; drop legacy/per-dep gcroots
            for f in "$ldx_dir"/gcroots/*; do
              [[ -e "$f" || -L "$f" ]] || continue
              b="$(basename "$f")"
              [[ "$b" == "deps" ]] || rm -f "$f"
            done
            rm -f "$ldx_dir/cache.json" 2>/dev/null || true

            # surgical luarc update: ldx owns workspace.library; every other
            # key (e.g. diagnostics.globals) is left untouched
            if [[ ''${#paths[@]} -eq 0 ]]; then
              paths_json="[]"
            else
              paths_json="$(printf '%s\n' "''${paths[@]}" | jq -R . | jq -s .)"
            fi
            tmp="$(mktemp)"
            existing="{}"
            [[ -s "$d/.luarc.json" ]] && existing="$(cat "$d/.luarc.json")"
            if ! echo "$existing" | jq --argjson p "$paths_json" '.workspace.library = ($p | unique)' > "$tmp"; then
              rm -f "$tmp"
              echo "ldx: error: $proj: failed to write .luarc.json" >&2
              return 1
            fi
            mv "$tmp" "$d/.luarc.json"

            echo "ldx: $proj: ok (''${#paths[@]} libraries)"
          }

          repo_="$(_ldx_repo)"
          project_dirs_tmp="$(mktemp)"
          if ! _ldx_projects "$repo_/apps" "$@" > "$project_dirs_tmp"; then
            rm -f "$project_dirs_tmp"
            exit 1
          fi
          mapfile -t project_dirs < "$project_dirs_tmp"
          rm -f "$project_dirs_tmp"
          failed=0
          for d in "''${project_dirs[@]}"; do
            if ! sync_project "$d" "$repo_/flake.lock"; then
              echo "ldx: sync failed: $d" >&2
              failed=1
            fi
          done
          exit $failed
        '';
      }
      {
        name = "check";
        description = "Verify all resolved references still point at existing directories (default: all)";
        flags = [repoFlag];
        arguments = [
          {
            name = "projects";
            description = "Project dirs/names (default: all)";
            variadic = true;
          }
        ];
        script = ''
          ${prelude}

          repo_="$(_ldx_repo)"
          project_dirs_tmp="$(mktemp)"
          if ! _ldx_projects "$repo_/apps" "$@" > "$project_dirs_tmp"; then
            rm -f "$project_dirs_tmp"
            exit 1
          fi
          mapfile -t project_dirs < "$project_dirs_tmp"
          rm -f "$project_dirs_tmp"
          failed=0
          for d in "''${project_dirs[@]}"; do
            st="$d/.ldx/state.json"
            if [[ ! -f "$st" ]]; then
              echo "ldx: $d: not synced (run 'ldx sync')" >&2
              failed=1
              continue
            fi
            if _ldx_lightcheck "$st"; then
              echo "ldx: $d: ok"
            else
              echo "ldx: $d: broken references found:" >&2
              while IFS=$'\t' read -r kind value; do
                [[ "$kind" == "literal" ]] && continue
                real="$(realpath "$value" 2>/dev/null || true)"
                if [[ -z "$real" || ! -d "$real" ]]; then
                  echo "ldx:   ''${value}" >&2
                fi
              done < <(jq -r '.deps[] | [.kind, (.value // "")] | @tsv' "$st")
              failed=1
            fi
          done
          exit $failed
        '';
      }
      {
        name = "env";
        description = "Print export LDX_* lines for the dev shell to source (default: all)";
        flags = [repoFlag];
        arguments = [
          {
            name = "projects";
            description = "Project dirs/names (default: all)";
            variadic = true;
          }
        ];
        script = ''
          ${prelude}

          repo_="$(_ldx_repo)"
          project_dirs_tmp="$(mktemp)"
          if ! _ldx_projects "$repo_/apps" "$@" > "$project_dirs_tmp"; then
            rm -f "$project_dirs_tmp"
            exit 1
          fi
          mapfile -t project_dirs < "$project_dirs_tmp"
          rm -f "$project_dirs_tmp"
          for d in "''${project_dirs[@]}"; do
            st="$d/.ldx/state.json"
            if [[ -f "$st" ]]; then
              jq -r '.deps[] | "export " + .var + "=\u0027" + .value + "\u0027"' "$st"
            else
              echo "ldx: warning: $d: not synced (run 'ldx sync')" >&2
            fi
          done
        '';
      }
      {
        name = "version";
        description = "Print version information";
        script = ''
          echo "ldx ${version}"
        '';
      }
    ];
  };
in
  cli // {inherit deps;}
