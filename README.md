# Lua Developer Experience

LDX is a small utility for resolving Lua dependencies through Nix to provide a better
developer experience.

It also has a Neovim plugin to manage workspace features, but that was
purged and re-added. It has not yet been tested again.

## Why

The core feature of LDX is resolving Lua dependencies, such as LuaRocks packages
through the Nix package manager, and updating the `.luarc.json` accordingly, so
you can enjoy better type support.

## How

LDX works by creating a `.ldx.json` file at the root of your project and then
running the `ldx` command. LDX fetches the dependencies, adds them to GC roots
and updates the `.luarc.json` with the resolved packages. The generated paths
are resolved through environment variables to avoid cross-machine path resolution
issues.

Currently, LDX works in two phases: first, it syncs the dependencies (by resolving
them and updating `.luarc.json`); then it sources the generated environment.
See [Example](#example).

Future versions will support evaluating the environment directly after syncing.

> [!INFO]
> LDX only updates the `workspace.library` field, and leaves the rest of `.luarc.json`
untouched.

## Limitations

LDX only supports dependencies that are packaged for Nix. They can be anywhere,
though, such as from the current flake, nixpkgs, or from the relative flakes. It
cannot fetch them from LuaRocks or other registries directly and there are no plans.
to add such features.

## Installation

Add `ldx` to your flake and add ldx to your dev shell.

```nix
{
    inputs = {
        # rest of your inputs
        ldx = {
            url = "github:ar-at-localhost/ar-at-localhost";
            nixpkgs.follow = "nixpkgs";
        };
    };
    # ...
    outputs = {
        #...
        # assuming system, pkgs variable
        devShells."$system" = {
            packages = [
                #...
                ldx.packages.$system.default
            ];

            shellHook = ''
                # Sync first
                ldx sync

                # Source the env
                eval $(ldx env)
            '';
        };
    };
}
```

## CLI Usage

Run `ldx --help` to see the available commands and usage instructions.

## Example

Let's say our workspace depends on Snacks.nvim, Orgmode.nvim, and is itself
a Neovim plugin. It therefore needs Neovim runtime, Snacks.nvim and Orgmode types
to provide an effective developer experience.

We'll create a `.ldx.json` and declare these dependencies.

```json
[
    "vim",
    "nixpkgs:vimPlugins.snacks-nvim"
    "nixpkgs:vimPlugins.orgmode"
]
```

As you can see, the configuration is simply a JSON array listing the dependencies,
in the supported format.

Once we run LDX, it resolves these dependencies, and our updated
`.luarc.json` may look like this:

```sh
# `.` refers to cwd as workspace root, assuming we're running from workspace root
# It is optional, though, and defaults to the current working directory.

# 1. Run ldx to fetch the dependencies and update the luarc
ldx sync .

# 2. Source the environment produced by the ldx to resolve environment variables
eval $(ldx env)
```

```json

{
  "workspace": {
    "library": [
      "${env:LDX_LOCAL____YALMS_LUA}",
      "${env:LDX_VIMPLUGINS_ORGMODE}",
      "${env:LDX_VIMPLUGINS_SNACKS_NVIM}",
      "${env:LDX_VIM_RUNTIME}"
    ]
  },
  "diagnostics": {
    "globals": []
  },
  "runtime": {
    "version": "LuaJIT",
    "path": [
      "./lua/?.lua",
      "./lua/?/init.lua"
    ]
  }
}
```

## Configuration Format

The configuration is a JSON array containing dependency names.
These names can follow one of the following formats:

### Keyword

Some dependencies may have a Keyword to add them. Currently,
`vim` is only such dependency. It resolves Neovim runtime libraries.

### Nixpkgs

These dependencies use a `nixpkgs:` prefix to indicate that they should
be reoslved from nixpkgs of the current flake.

#### Examples

- `nixpkgs:vimPlugins.snacks-nvim` Neovim Snacks
- `nixpkgs:vimPlugins.orgmode` Neovim Orgmode
- `nixpkgs:vimPlugins.plenary-nvim` Neovim Plenary

> [!NOTE]
> You need to provide full attribute path, if package is nested within package sets,
> as in the `vimPlugins` examples above.

### Flake Packages

Packages from current flake or other relative flakes are added with relative
flake URI. For example, `.#foo`, `..#bar` etc.

#### Examples <-- markdownlint-ignore no-duplicate-heading>

- `..#foo`
- `.#foo`
- `./bar/baz#foo`

### Relative Lua workspaces

Relative Lua workspaces can be packaged directly.

#### Examples <-- markdownlint-ignore no-duplicate-heading -->

- `../`
- `./foo`
- `./bar/baz/foo`
