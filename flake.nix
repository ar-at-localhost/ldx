{
  description = "LDX - Lua Developer Experience";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";

    yalms = {
      url = "github:ar-at-localhost/yalms";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, ...} @ inputs: let
    inherit (inputs.nixpkgs) lib;

    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    forEachSupportedSystem = f:
      lib.genAttrs supportedSystems (
        system:
          f {
            inherit self system;
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [inputs.yalms.overlays.default];
            };
          }
      );

    mkOutputs = pkgs: {
          default = pkgs.callPackage ./default.nix {};

          vimPlugins = pkgs.callPackage ./vim-plugin.nix {};
        };
  in {
    packages = forEachSupportedSystem (
      {pkgs, ...}: mkOutputs pkgs
    );

    overlays.default = final: prev: (let outputs = mkOutputs prev; in {
      ldx = outputs.default;
      vimPlugins = prev.vimPlugins // {
        ldx = outputs.vimPlugin;
      };
    });

    checks = forEachSupportedSystem (
      {pkgs, ...}: mkOutputs pkgs
    );

    nixvimModules.ldx = ./nixvim.nix;
  };
}
