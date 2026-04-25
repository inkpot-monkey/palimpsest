{ inputs, self, ... }:
let
  overlays = import ../modules/shared/overlays { inherit inputs; };
  helpers = inputs.nixpkgs.lib // {
    inherit overlays;

    mkPkgs =
      system:
      let
        unstable = import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      in
      import inputs.nixpkgs {
        inherit system;
        overlays = [ overlays.default ];
        config = {
          allowUnfree = true;
        };
      }
      // {
        inherit unstable;
      };

    getSecretFile = name: ../secrets + "/profiles/${name}.yaml";
    getHostSecretFile = host: ../secrets + "/hosts/${host}/secrets.yaml";
    getHostNamedSecretFile = host: name: ../secrets + "/hosts/${host}/${name}.yaml";
    getUserSecretFile = user: ../secrets + "/users/${user}.yaml";

    mkSystem =
      {
        system,
        modules,
        specialArgs ? { },
      }:
      let
        unstable = import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      in
      inputs.nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit (self) settings;
          inherit
            inputs
            self
            unstable
            ;
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
        system,
        modules,
        specialArgs ? { },
      }:
      let
        unstable = import inputs.nixpkgs-unstable {
          inherit system;
          config.allowUnfree = true;
        };
      in
      inputs.nixos-raspberrypi.lib.nixosSystem {
        specialArgs = {
          inherit (self) settings;
          inherit
            inputs
            self
            unstable
            ;
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
