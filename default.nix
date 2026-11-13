{pkgs, ...}: let
  pog = import (fetchTarball {
    name = "pog-2026-11-26";
    url = "https://github.com/jpetrucciani/pog/archive/main.tar.gz";
    sha256 = "sha256:13nydq0a5sjan5j9g1y8qv1gs8y16pn35nwixahnkqwxyflkmfpy";
  }) {
      inherit pkgs;
    };

  versionInfo = import ./version.nix;
  inherit (versionInfo) version;
  inherit (builtins) toJSON;
  inherit (pkgs) lib;

  cfg = {
    name = "ldx";
    envPrefix = "LDX";
    manifest = ".ldx.json";
    stateDirName = ".ldx";
    stateFileName = "state.json";
    errFileName = "sync.err";
    libDirName = "lib";
    gcrootsDirName = "gcroots";
    luarcName = ".luarc.json";
    luarcLibraryPath = ".workspace.library";
    lockFile = "flake.lock";
    fingerprintSalt = "ldx-state-rev3";
    localPrefixes = ["./" "../"];
    relativeFlakeRoots = ["." ".."];
    defaultFlake = "nixpkgs";
    defaultSubdir = "lua";
    refSeparator = ":";
  };

  inherit
    (cfg)
    name
    envPrefix
    manifest
    stateDirName
    stateFileName
    errFileName
    libDirName
    gcrootsDirName
    luarcName
    luarcLibraryPath
    lockFile
    fingerprintSalt
    localPrefixes
    relativeFlakeRoots
    defaultFlake
    defaultSubdir
    refSeparator
    ;

  inherit (builtins) storeDir;

  localPattern = lib.concatMapStringsSep "|" (p: "${p}*") localPrefixes;
  relPattern = lib.concatStringsSep "|" (relativeFlakeRoots ++ [localPattern]);

  specialRefs = {
    luv = {
      kind = "literal";
      var = "${envPrefix}_LUV_LIBRARY";
      name = "luv";
      path = "\${3rd}/luv/library";
    };
    vim = {
      kind = "nixpkgs";
      var = "${envPrefix}_VIM_RUNTIME";
      name = "nvim";
      attr = "neovim-unwrapped";
      subdir = "share/nvim/runtime/lua";
    };
  };

  specialRefsFile = pkgs.writeText "${name}-special-refs.json" (toJSON specialRefs);

  workspacesArgument = {
    name = "workspaces";
    description = "Workspace dirs (default: current directory)";
    variadic = true;
  };

  prelude = ''
    # each argument must be a dir holding a manifest; no arguments means the cwd
    _ldx_workspaces() {
      local w d
      if [[ $# -eq 0 ]]; then
        set -- "$PWD"
      fi
      for w in "$@"; do
        d="$({ cd "$w" 2>/dev/null && pwd; } || true)"
        if [[ -z "$d" || ! -f "$d/${manifest}" ]]; then
          echo "${name}: error: no manifest at $w/${manifest}" >&2
          return 1
        fi
        echo "$d"
      done
    }

    # nearest ancestor (or self) holding the flake lockfile
    _ldx_flake_dir() {
      local p="$1"
      while [[ "$p" != "/" ]]; do
        if [[ -f "$p/${lockFile}" ]]; then
          echo "$p"
          return 0
        fi
        p="$(dirname "$p")"
      done
      return 1
    }

    _ldx_sanitize() {
      printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g' | tr '[:lower:]' '[:upper:]'
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

    # manifest + lockfile are the only inputs that can alter resolution; the
    # salt is bumped whenever resolution semantics change
    _ldx_fingerprint() {
      local d="$1" lock="$2"
      { echo "${fingerprintSalt}"; cat "$d/${manifest}"; [[ -z "$lock" ]] || cat "$lock"; } | sha256sum | cut -d' ' -f1
    }

    # every non-literal reference must still resolve to a real directory
    _ldx_lightcheck() {
      local st="$1" kind value real bad=0
      [[ -f "$st" ]] || return 1
      while IFS=$'\t' read -r kind value; do
        [[ "$kind" == "literal" ]] && continue
        # a local dep must be a live working-tree path, never a store copy
        if [[ "$kind" == "local" && "$value" == ${storeDir}/* ]]; then
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

  cli = pog.pog {
    inherit name version;
    description = "Lua dependency manager: resolves nvim LSP library references (${luarcName})";

    runtimeInputs = [pkgs.jq pkgs.findutils pkgs.gnused pkgs.coreutils];

    commands = [
      {
        name = "sync";
        description = "Resolve dependencies and update ${luarcName} for workspaces (default: current directory)";
        arguments = [workspacesArgument];
        script = ''
          ${prelude}

          # sets kind, var, name, path, inst, subdir, attr in the caller's scope
          resolve_ref() {
            local ref="$1" sp flake_ rel
            local -a parts=()
            kind="" var="" name="" path="" inst="" subdir="" attr=""

            sp="$(jq -c --arg r "$ref" '.[$r] // empty' "${specialRefsFile}")"
            if [[ -n "$sp" ]]; then
              kind="$(jq -r '.kind' <<< "$sp")"
              var="$(jq -r '.var' <<< "$sp")"
              name="$(jq -r '.name // ""' <<< "$sp")"
              path="$(jq -r '.path // ""' <<< "$sp")"
              subdir="$(jq -r '.subdir // ""' <<< "$sp")"
              attr="$(jq -r '.attr // ""' <<< "$sp")"
              [[ -z "$attr" ]] || inst="${defaultFlake}#$attr"
              return 0
            fi

            if [[ "$ref" == *"#"* ]]; then
              flake_="''${ref%%#*}"
              attr="''${ref#*#}"
              case "$flake_" in
                ${relPattern}) ;;
                *)
                  echo "${name}: error: $ws: unsupported flake '$flake_' in ref '$ref'" >&2
                  return 1
                  ;;
              esac
              rel="$(realpath -m "$d/$flake_")"
              kind="flake"
              name="$(_ldx_sanitize "$ref")"
              var="${envPrefix}_FLAKE_$name"
              subdir="${defaultSubdir}"
              inst="$rel#$attr"
              return 0
            fi

            case "$ref" in
              ${localPattern})
                kind="local"
                name="$(_ldx_sanitize "$ref")"
                var="${envPrefix}_LOCAL_$name"
                path="$ref"
                return 0
                ;;
            esac

            IFS='${refSeparator}' read -ra parts <<< "$ref"
            if [[ ''${#parts[@]} -eq 1 ]]; then
              flake_="${defaultFlake}"
              attr="''${parts[0]}"
            else
              flake_="''${parts[0]}"
              attr="''${parts[1]}"
            fi
            if [[ "$flake_" != "${defaultFlake}" ]]; then
              echo "${name}: error: $ws: unsupported flake '$flake_' in ref '$ref'" >&2
              return 1
            fi
            kind="nixpkgs"
            name="$(_ldx_sanitize "$attr")"
            var="${envPrefix}_$name"
            subdir="''${parts[2]:-${defaultSubdir}}"
            inst="$flake_#$attr"
          }

          sync_workspace() {
            local d="$1"
            local ws state_dir fp stored st flake_dir lock link err ref
            local kind var name path subdir inst attr value realp abs tmp existing
            local -a deps_json=() paths=() names=() roots=() flags=()
            ws="$(basename "$d")"
            state_dir="$d/${stateDirName}"
            st="$state_dir/${stateFileName}"
            err="$state_dir/${errFileName}"

            if ! jq -e 'type == "array"' "$d/${manifest}" > /dev/null 2>&1; then
              echo "${name}: error: $ws: ${manifest} must be a JSON array" >&2
              return 1
            fi

            mkdir -p "$state_dir/${libDirName}" "$state_dir/${gcrootsDirName}" || return 1

            flake_dir="$(_ldx_flake_dir "$d" || true)"
            lock=""
            [[ -z "$flake_dir" ]] || lock="$flake_dir/${lockFile}"

            fp="$(_ldx_fingerprint "$d" "$lock")"
            stored="$(jq -r '.fingerprint // ""' "$st" 2>/dev/null || true)"

            # fast path: nothing changed and references still exist
            if [[ "$fp" == "$stored" ]] && _ldx_lightcheck "$st"; then
              echo "${name}: $ws: up to date"
              return 0
            fi

            echo "${name}: $ws: resolving dependencies..."

            while IFS= read -r ref; do
              [[ -n "$ref" ]] || continue
              resolve_ref "$ref" || return 1
              value=""

              case "$kind" in
                nixpkgs|flake)
                  link="$state_dir/${gcrootsDirName}/$name"
                  flags=()
                  if [[ "$kind" == "nixpkgs" && -n "$flake_dir" ]]; then
                    flags=(--inputs-from "$flake_dir")
                  fi
                  # the out-link protects the dependency from the garbage collector
                  if ! nix build "''${flags[@]}" "$inst" --out-link "$link" 2>"$err"; then
                    echo "${name}: error: $ws: $var: resolution of '$inst' failed:" >&2
                    sed 's/^/${name}:   /' "$err" >&2 2>/dev/null || true
                    rm -f "$err"
                    return 1
                  fi
                  rm -f "$err"
                  path="$(realpath "$link")"
                  if [[ -z "$subdir" || ! -d "$path/$subdir" ]]; then
                    echo "${name}: error: $ws: $var: missing library dir at $path/$subdir" >&2
                    return 1
                  fi
                  ln -sfn "$path/$subdir" "$state_dir/${libDirName}/$name"
                  value="$state_dir/${libDirName}/$name"
                  names+=("$name")
                  roots+=("$name")
                  ;;
                local)
                  # resolved against the real workspace dir, never the nix store
                  case "$path" in
                    /*) abs="$path" ;;
                    *)  abs="$d/$path" ;;
                  esac
                  realp="$(realpath -m "$abs" 2>/dev/null || true)"
                  if [[ -z "$realp" || ! -d "$realp" ]]; then
                    echo "${name}: error: $ws: $var: local dependency not found at $abs" >&2
                    return 1
                  fi
                  value="$realp"
                  ;;
                literal)
                  value="$path"
                  ;;
                *)
                  echo "${name}: error: $ws: unknown kind '$kind' for $var" >&2
                  return 1
                  ;;
              esac

              paths+=("\''${env:''${var}}")
              deps_json+=("$(jq -nc --arg var "$var" --arg kind "$kind" --arg name "$name" --arg value "$value" --arg path "$path" --arg subdir "$subdir" '{var: $var, kind: $kind, name: $name, value: $value, path: $path, subdir: $subdir}')")
            done < <(jq -r '.[]' "$d/${manifest}")

            local deps_json_s paths_json
            if [[ ''${#deps_json[@]} -eq 0 ]]; then
              deps_json_s="[]"
            else
              deps_json_s="$(printf '%s\n' "''${deps_json[@]}" | jq -s .)"
            fi
            echo "$deps_json_s" | jq --arg workspace "$ws" --arg fingerprint "$fp" '{workspace: $workspace, fingerprint: $fingerprint, deps: .}' > "$st"

            # prune lib links and gc roots that are no longer in the manifest
            for f in "$state_dir"/${libDirName}/*; do
              [[ -e "$f" || -L "$f" ]] || continue
              b="$(basename "$f")"
              if ! _contains "$b" "''${names[@]}"; then
                rm -f "$f"
              fi
            done
            for f in "$state_dir"/${gcrootsDirName}/*; do
              [[ -e "$f" || -L "$f" ]] || continue
              b="$(basename "$f")"
              if ! _contains "$b" "''${roots[@]}"; then
                rm -f "$f"
              fi
            done
            rm -f "$state_dir/cache.json" 2>/dev/null || true

            # only the library key is rewritten; every other key is left untouched
            if [[ ''${#paths[@]} -eq 0 ]]; then
              paths_json="[]"
            else
              paths_json="$(printf '%s\n' "''${paths[@]}" | jq -R . | jq -s .)"
            fi
            tmp="$(mktemp)"
            existing="{}"
            [[ -s "$d/${luarcName}" ]] && existing="$(cat "$d/${luarcName}")"
            if ! echo "$existing" | jq --argjson p "$paths_json" '${luarcLibraryPath} = ($p | unique)' > "$tmp"; then
              rm -f "$tmp"
              echo "${name}: error: $ws: failed to write ${luarcName}" >&2
              return 1
            fi
            mv "$tmp" "$d/${luarcName}"

            echo "${name}: $ws: ok (''${#paths[@]} libraries)"
          }

          workspaces_tmp="$(mktemp)"
          if ! _ldx_workspaces "$@" > "$workspaces_tmp"; then
            rm -f "$workspaces_tmp"
            exit 1
          fi
          mapfile -t workspace_dirs < "$workspaces_tmp"
          rm -f "$workspaces_tmp"
          failed=0
          for d in "''${workspace_dirs[@]}"; do
            if ! sync_workspace "$d"; then
              echo "${name}: sync failed: $d" >&2
              failed=1
            fi
          done
          exit $failed
        '';
      }
      {
        name = "check";
        description = "Verify all resolved references still point at existing directories (default: current directory)";
        arguments = [workspacesArgument];
        script = ''
          ${prelude}

          workspaces_tmp="$(mktemp)"
          if ! _ldx_workspaces "$@" > "$workspaces_tmp"; then
            rm -f "$workspaces_tmp"
            exit 1
          fi
          mapfile -t workspace_dirs < "$workspaces_tmp"
          rm -f "$workspaces_tmp"
          failed=0
          for d in "''${workspace_dirs[@]}"; do
            st="$d/${stateDirName}/${stateFileName}"
            if [[ ! -f "$st" ]]; then
              echo "${name}: $d: not synced (run '${name} sync')" >&2
              failed=1
              continue
            fi
            if _ldx_lightcheck "$st"; then
              echo "${name}: $d: ok"
            else
              echo "${name}: $d: broken references found:" >&2
              while IFS=$'\t' read -r kind value; do
                [[ "$kind" == "literal" ]] && continue
                real="$(realpath "$value" 2>/dev/null || true)"
                if [[ -z "$real" || ! -d "$real" ]]; then
                  echo "${name}:   ''${value}" >&2
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
        description = "Print export ${envPrefix}_* lines for the dev shell to source (default: current directory)";
        arguments = [workspacesArgument];
        script = ''
          ${prelude}

          workspaces_tmp="$(mktemp)"
          if ! _ldx_workspaces "$@" > "$workspaces_tmp"; then
            rm -f "$workspaces_tmp"
            exit 1
          fi
          mapfile -t workspace_dirs < "$workspaces_tmp"
          rm -f "$workspaces_tmp"
          for d in "''${workspace_dirs[@]}"; do
            st="$d/${stateDirName}/${stateFileName}"
            if [[ -f "$st" ]]; then
              jq -r '.deps[] | "export " + .var + "=\u0027" + .value + "\u0027"' "$st"
            else
              echo "${name}: warning: $d: not synced (run '${name} sync')" >&2
            fi
          done
        '';
      }
      {
        name = "version";
        description = "Print version information";
        script = ''
          echo "${name} ${version}"
        '';
      }
    ];
  };
in
  cli
