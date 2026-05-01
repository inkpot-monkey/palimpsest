{ inputs, self, ... }:
let
  overlays = import ../modules/shared/overlays { inherit inputs; };
  lib = inputs.nixpkgs.lib;
  helpers = lib // {
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

    getSecretPath =
      subpath:
      let
        path = "${inputs.secrets}/${subpath}";
        isNix = inputs.nixpkgs.lib.hasSuffix ".nix" subpath;
        fallback = if isNix then ../parts/mock-identities.nix else ../parts/mock-secrets.yaml;
      in
      if builtins.pathExists path then path else fallback;

    getSecretFile =
      name:
      let
        path = "${inputs.secrets}/profiles/${name}.yaml";
      in
      if builtins.pathExists path then path else ../parts/mock-secrets.yaml;

    getHostSecretFile =
      host:
      let
        path = "${inputs.secrets}/hosts/${host}/secrets.yaml";
      in
      if builtins.pathExists path then path else ../parts/mock-secrets.yaml;

    getHostNamedSecretFile =
      host: name:
      let
        path = "${inputs.secrets}/hosts/${host}/${name}.yaml";
      in
      if builtins.pathExists path then path else ../parts/mock-secrets.yaml;

    getUserSecretFile =
      user:
      let
        path = "${inputs.secrets}/users/${user}.yaml";
      in
      if builtins.pathExists path then path else ../parts/mock-secrets.yaml;

    # Email Config Helpers
    mkMbsyncAccount =
      {
        name,
        host,
        user,
        passCmd,
        port ? null,
        tlsType ? "IMAPS",
        authMechs ? "LOGIN",
        extraConfig ? "",
      }:
      ''
        IMAPAccount ${name}
        Host ${host}
        User ${user}
        PassCmd "${passCmd}"
        AuthMechs ${authMechs}
        TLSType ${tlsType}
        ${lib.optionalString (port != null) "Port ${builtins.toString port}"}
        ${extraConfig}
      '';

    mkMbsyncChannel =
      {
        name,
        account,
        far,
        near,
        patterns ? "*",
        create ? "Both",
        expunge ? "Both",
        remove ? "None",
      }:
      ''
        Channel ${name}
        Far :${account}-remote:${far}
        Near :${account}-local:${near}
        Patterns ${patterns}
        Create ${create}
        Expunge ${expunge}
        Remove ${remove}
      '';

    mkSystem =
      {
        system,
        modules,
        specialArgs ? { },
      }:
      inputs.nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit (self) settings;
          inherit
            inputs
            self
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
      inputs.nixos-raspberrypi.lib.nixosSystem {
        specialArgs = {
          inherit (self) settings;
          inherit
            inputs
            self
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
