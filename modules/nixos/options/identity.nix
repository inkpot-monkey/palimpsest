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
    users.users = lib.mapAttrs (_username: userCfg: {
      isNormalUser = true;
      inherit (userCfg.identity) hashedPassword extraGroups;
      description = userCfg.identity.name;
      openssh.authorizedKeys.keys = lib.optional (userCfg.identity.sshKey != "") userCfg.identity.sshKey;
    }) config.custom.users;
  };
}
