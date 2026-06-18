{ inputs, self, ... }:
let
  overlays = import ../modules/shared/overlays { inherit inputs; };
  inherit (inputs.nixpkgs) lib;

  # The getSecret* helpers fall back to checked-in mock files when a path is absent
  # from the `secrets` input, so the flake evaluates standalone (public clone / fresh
  # checkout before secrets are wired). The fallback is deliberately LOUD — a silent
  # mock substitution during a real build would mask a missing/mis-pathed secret, so
  # each fallback warns. (Originally added for Garnix CI, now defunct; the standalone
  # eval-ability is kept for the public repo. See docs/adr/0012.)
  warnMock =
    what: fallback:
    lib.warn "secrets: '${what}' not present in the secrets input — falling back to a MOCK; real secrets are NOT used." fallback;

  helpers = lib // {
    inherit overlays;

    # Recipients-from-grants (ADR-0015, slice 06): derive, for each secret-bearing
    # feature's sops file, the set of hosts that should be able to decrypt it — namely
    # the hosts that GRANT that feature. This is the single source of truth for the
    # stash's .sops.yaml recipients, so they can never silently drift from the grants
    # (and, since the exposed-host assertion forbids granting a secret-bearing feature
    # on an exposed host, no such host can ever become a recipient).
    #   { "<stash-relative sops file>" = [ "<hostname>" ... ]; }
    mkFeatureRecipients =
      nixosConfigurations:
      let
        meta = self.contract.featureMeta;
        secretFeatures = lib.filter (f: meta.${f}.secretBearing or false) (lib.attrNames meta);
        hostNames = lib.attrNames nixosConfigurations;
        hostGrants =
          host: feature:
          lib.any (u: u.granted.${feature}.enable or false) (
            lib.attrValues nixosConfigurations.${host}.config.custom.users
          );
      in
      lib.foldl' (
        acc: feature:
        let
          hosts = lib.filter (h: hostGrants h feature) hostNames;
        in
        lib.foldl' (a: file: a // { ${file} = lib.unique ((a.${file} or [ ]) ++ hosts); }) acc (
          meta.${feature}.secretFiles or [ ]
        )
      ) { } secretFeatures;

    featureRecipients = helpers.mkFeatureRecipients self.nixosConfigurations;

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
      if builtins.pathExists path then path else warnMock subpath fallback;

    getSecretFile =
      name:
      let
        path = "${inputs.secrets}/profiles/${name}.yaml";
      in
      if builtins.pathExists path then
        path
      else
        warnMock "profiles/${name}.yaml" ../parts/mock-secrets.yaml;

    getHostSecretFile =
      host:
      let
        path = "${inputs.secrets}/hosts/${host}/secrets.yaml";
      in
      if builtins.pathExists path then
        path
      else
        warnMock "hosts/${host}/secrets.yaml" ../parts/mock-secrets.yaml;

    getHostNamedSecretFile =
      host: name:
      let
        path = "${inputs.secrets}/hosts/${host}/${name}.yaml";
      in
      if builtins.pathExists path then
        path
      else
        warnMock "hosts/${host}/${name}.yaml" ../parts/mock-secrets.yaml;

    getUserSecretFile =
      user:
      let
        path = "${inputs.secrets}/users/${user}.yaml";
      in
      if builtins.pathExists path then path else warnMock "users/${user}.yaml" ../parts/mock-secrets.yaml;

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
