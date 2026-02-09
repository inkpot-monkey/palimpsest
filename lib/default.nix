{ inputs, self, ... }:
let
  overlays = import ../modules/shared/overlays { inherit inputs; };
  keys = import ../modules/shared/keys.nix;

  mkPkgs =
    system:
    import inputs.nixpkgs {
      inherit system;
      overlays = [ overlays.default ];
      config = {
        allowUnfree = true;
      };
    };

  mkSystem =
    {
      modules,
      system ? "x86_64-linux",
      specialArgs ? { },
    }:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit inputs self keys;
      }
      // specialArgs;
      modules = modules ++ [
        {
          nixpkgs.overlays = [ overlays.default ];
          nixpkgs.config.allowUnfree = true;
        }
      ];
    };
in
{
  inherit
    mkPkgs
    mkSystem
    keys
    overlays
    ;
}
