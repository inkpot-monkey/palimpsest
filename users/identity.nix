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
  };
}
