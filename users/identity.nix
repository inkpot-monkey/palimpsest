{
  lib,
  config,
  self,
  ...
}:
{
  options.custom.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        # Identity schema comes from the shared contract (ADR-0015), shared with the
        # home-level `identity` options so the two can't drift.
        options.identity = import self.contract.identity { inherit lib; };
        # Feature grants a host makes for this user, from the contract's vocabulary.
        # Default-closed (ADR-0015, mechanic 2): a host enables `granted.<feature>`.
        options.granted = import self.contract.features { inherit lib; };
      }
    );
    default = { };
    description = "User-specific configurations including identity";
  };

  # Platform interface (ADR-0015), system side — bound below.
  options.custom.platform = import self.contract.platform { inherit lib; };

  # Marks a host as exposed/agent-facing (e.g. runs a code-executing agent). Such a
  # host must not be granted any secret-bearing feature (ADR-0015 threat model).
  options.custom.host.exposed = lib.mkEnableOption "an exposed/agent-facing host that may not be granted secret-bearing features";

  config = {
    # 1. Enable services transparently if any user has a "gui" profile
    networking.networkmanager.enable = lib.mkIf (lib.any (user: user.identity.profile == "gui") (
      lib.attrValues config.custom.users
    )) true;
    services.displayManager.sddm = {
      enable = lib.mkIf (lib.any (user: user.identity.profile == "gui") (
        lib.attrValues config.custom.users
      )) (lib.mkDefault true);
      wayland.enable = lib.mkIf (lib.any (user: user.identity.profile == "gui") (
        lib.attrValues config.custom.users
      )) (lib.mkDefault true);
    };

    # 2. Map custom users to system users
    users.users = lib.mapAttrs (_username: userCfg: {
      isNormalUser = true;
      inherit (userCfg.identity) hashedPassword extraGroups;
      description = userCfg.identity.name;
      openssh.authorizedKeys.keys =
        lib.optional (userCfg.identity.sshKey != "") userCfg.identity.sshKey
        ++ userCfg.identity.trustedKeys;
    }) config.custom.users;

    # 3. Host-side platform binding (ADR-0015): the single place the system names
    # the secrets backend, so features resolve secrets host-agnostically.
    custom.platform = {
      secretFile = name: self.lib.getSecretFile name;
      secretPath = subpath: self.lib.getSecretPath subpath;
    };

    # 4. An exposed host must not be granted any secret-bearing feature — no grant,
    # no re-key, no cleartext on the box most likely to be compromised.
    assertions = lib.optional config.custom.host.exposed (
      let
        meta = self.contract.featureMeta;
        offending = lib.concatMap (
          uname:
          let
            granted = config.custom.users.${uname}.granted;
          in
          lib.filter (fname: (granted.${fname}.enable or false) && (meta.${fname}.secretBearing or false)) (
            lib.attrNames meta
          )
        ) (lib.attrNames config.custom.users);
      in
      {
        assertion = offending == [ ];
        message = "exposed host '${config.networking.hostName}' must not be granted secret-bearing feature(s): ${lib.concatStringsSep ", " offending}";
      }
    );
  };
}
