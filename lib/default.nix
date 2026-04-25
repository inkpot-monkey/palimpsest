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
 
    getSecretPath =
      subpath:
      let
        path = ./. + "/../secrets/${subpath}";
        isNix = inputs.nixpkgs.lib.hasSuffix ".nix" subpath;
        fallback = if isNix then ../parts/mock-identities.nix else ../parts/mock-secrets.yaml;
      in
      if builtins.pathExists path then path else fallback;

    getSecretFile =
      name:
      let
        path = ./. + "/../secrets/profiles/${name}.yaml";
      in
      if builtins.pathExists path then path else ../parts/mock-secrets.yaml;

    getHostSecretFile =
      host:
      let
        path = ./. + "/../secrets/hosts/${host}/secrets.yaml";
      in
      if builtins.pathExists path then path else ../parts/mock-secrets.yaml;

    getHostNamedSecretFile =
      host: name:
      let
        path = ./. + "/../secrets/hosts/${host}/${name}.yaml";
      in
      if builtins.pathExists path then path else ../parts/mock-secrets.yaml;

    getUserSecretFile =
      user:
      let
        path = ./. + "/../secrets/users/${user}.yaml";
      in
      if builtins.pathExists path then path else ../parts/mock-secrets.yaml;

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
