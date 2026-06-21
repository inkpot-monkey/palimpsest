# Shared declaration of the per-user identity option set — part of the host↔user
# contract (ADR-0015). Used by BOTH umbrella modules so the system-level
# `custom.users.<user>.identity` submodule and the home-level `identity` options
# describe the same data and can't drift; the host bridges the two when it binds a user.
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
    default = "cli";
    # Inert in the system path (grants gate now, not the profile); still read by the
    # standalone mkHome path and the conformance matrix. Defaulted so a manifest need
    # not carry it (ADR-0018 review, finding 4).
    description = "Profile type (legacy; grants gate host config now).";
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
