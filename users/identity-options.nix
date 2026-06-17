# Shared declaration of the per-user identity option set. Used by both option paths that
# describe the same data, to keep them from drifting:
#   - the system-level `custom.users.<user>.identity` submodule (users/identity.nix)
#   - the home-manager-level `identity` options (modules/homeManager/options.nix)
# The two are bridged by `inherit identity` in users/inkpotmonkey/nixos/default.nix.
{ lib }:
{
  name = lib.mkOption {
    type = lib.types.str;
    description = "User's full name";
  };
  email = lib.mkOption {
    type = lib.types.str;
    description = "User's email address";
  };
  gmail = lib.mkOption {
    type = lib.types.str;
    description = "User's gmail address";
    default = "";
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
  trustedKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    description = "List of trusted public SSH keys for this user";
    default = [ ];
  };
}
