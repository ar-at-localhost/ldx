{pkgs, ...}: let
  inherit (import ./version.nix) version;

  src = pkgs.lib.cleanSourceWith {
    src = ./.;
    filter = path: _type: let
      base = builtins.baseNameOf path;
    in
      base != ".ldx";
  };
in
  pkgs.vimUtils.buildVimPlugin {
    pname = "ldx";
    inherit version src;
    dependencies = [
      pkgs.vimPlugins.yalms
      pkgs.vimPlugins.snacks-nvim
    ];
    doCheck = false;
  }
