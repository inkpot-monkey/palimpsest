{ ... }:

{
  # Input Devices (Touchpad)
  services.libinput.enable = true;

  # Security
  security.polkit.enable = true;

  # Services
  services.upower.enable = true;
  services.gnome.gnome-keyring.enable = true;
}
