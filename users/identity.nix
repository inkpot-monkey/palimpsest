{
  lib,
  config,
  ...
}:
{
  options.custom.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.identity = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "User's full name";
          };
          email = lib.mkOption {
            type = lib.types.str;
            description = "User's email address";
          };
          sshKey = lib.mkOption {
            type = lib.types.str;
            description = "User's public SSH key";
            default = "";
          };
          username = lib.mkOption {
            type = lib.types.str;
            description = "System username";
          };
          hashedPassword = lib.mkOption {
            type = lib.types.str;
            description = "User's hashed password";
            default = "";
          };
          profile = lib.mkOption {
            type = lib.types.enum [
              "cli"
              "gui"
            ];
            description = "Profile type for conditional configuration";
          };
          extraGroups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Additional groups for the user";
            default = [ ];
          };
        };
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
      openssh.authorizedKeys.keys = lib.optional (userCfg.identity.sshKey != "") userCfg.identity.sshKey;
    }) config.custom.users;
  };
}
