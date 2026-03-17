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
    username = lib.mkOption {
      type = lib.types.str;
      description = "System username";
    };
    hashedPassword = lib.mkOption {
      type = lib.types.str;
      description = "User's hashed password";
    };
    profile = lib.mkOption {
      type = lib.types.enum [
        "cli"
        "gui"
      ];
      description = "Profile type for conditional configuration";
    };
  };

  config.identity = {
    profile = lib.mkDefault "cli";
    username = "inkpotmonkey";
    hashedPassword = "<SCRUBBED_PASSWORD>";
    name = "thomassdk";
    email = "<SCRUBBED_EMAIL>";
    sshKey = "<SCRUBBED_SSH_KEY>";
  };
}
