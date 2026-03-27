{ lib, ... }:
{
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

  options.custom.home.profiles = {
    cli.enable = lib.mkEnableOption "CLI meta-profile (base tools)";
    gui.enable = lib.mkEnableOption "GUI meta-profile (desktop environment)";
  };
}
