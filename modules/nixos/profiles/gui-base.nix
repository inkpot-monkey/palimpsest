{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.gui-base;
in
{
  options.custom.profiles.gui-base = {
    enable = lib.mkEnableOption "GUI base configuration (polkit, libinput, upower)";
  };

  config = lib.mkIf cfg.enable {
    # Input Devices (Touchpad)
    services.libinput.enable = true;

    # Security
    security.polkit.enable = true;

    # Services
    services.upower.enable = true;
    services.gnome.gnome-keyring.enable = true;
  };
}
