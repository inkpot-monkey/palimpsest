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
    };
    profile = lib.mkOption {
      type = lib.types.enum [
        "cli"
        "gui"
      ];
      default = "cli";
      description = "Profile type for conditional configuration";
    };
  };

  config.identity = {
    name = "thomassdk";
    email = "<SCRUBBED_EMAIL>";
    sshKey = "<SCRUBBED_SSH_KEY>";
  };
}
