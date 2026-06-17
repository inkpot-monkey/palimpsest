{ lib, ... }:
{
  # Field set shared with the system-level `custom.users.<user>.identity` submodule —
  # see ../../users/identity-options.nix. Populated from the system identity via
  # `inherit identity` in users/inkpotmonkey/nixos/default.nix.
  options.identity = import ../../users/identity-options.nix { inherit lib; };

  options.custom.home.profiles = {
    cli.enable = lib.mkEnableOption "CLI meta-profile (base tools)";
    gui.enable = lib.mkEnableOption "GUI meta-profile (desktop environment)";
  };
}
