{
  description = "LDX - Lua Developer Experience";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    pog = {
      url = "github:jpetrucciani/pog";
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
              overlays = [inputs.pog.overlays.default];
            };
          }
      );

    mkOutputs = pkgs: {
          ldx = pkgs.callPackage ./default.nix {};

          vimPlugins.ldx = pkgs.callPackage ./vim-plugin.nix {};
        };
  in {
    packages = forEachSupportedSystem (
      {pkgs, ...}: mkOutputs pkgs
    );

    checks = forEachSupportedSystem (
      {pkgs, ...}: mkOutputs pkgs
    );

    nixvimModules.ldx = ./nixvim.nix;
  };
}
