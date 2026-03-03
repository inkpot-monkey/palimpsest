{ inputs, self, ... }:
let
  overlays = import ../modules/shared/overlays { inherit inputs; };
  helpers = inputs.nixpkgs.lib // {
    inherit overlays;

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
        specialArgs ? { },
      }:
      inputs.nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit (self) settings;
          inherit inputs self;
          homeManagerInput = inputs.home-manager;
        }
        // specialArgs;
        modules = modules ++ [
          {
            nixpkgs.overlays = [ overlays.default ];
            nixpkgs.config.allowUnfree = true;
          }
        ];
      };

    mkPiSystem =
      {
        modules,
        specialArgs ? { },
      }:
      inputs.nixos-raspberrypi.lib.nixosSystem {
        specialArgs = {
          inherit (self) settings;
          inherit inputs self;
          inherit (inputs) nixos-raspberrypi;
          homeManagerInput = inputs.home-manager;
        }
        // specialArgs;
        modules = modules ++ [
          {
            nixpkgs.overlays = [ overlays.default ];
            nixpkgs.config.allowUnfree = true;
          }
        ];
      };
  };
in
{
  flake.overlays = helpers.overlays.modifications;
  flake.lib = helpers;
}
