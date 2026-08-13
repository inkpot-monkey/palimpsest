{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.bluetooth;
in
{
  options.custom.profiles.bluetooth = {
    enable = lib.mkEnableOption "bluetooth configuration";
  };

  config = lib.mkIf cfg.enable {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
      # `settings` writes /etc/bluetooth/main.conf, which bluetoothd validates strictly and
      # complains about per boot for anything it doesn't own:
      #   src/main.c:check_options() Unknown key UserspaceHID for group General in …/main.conf
      #   src/main.c:check_config()  Unknown group Input in …/main.conf
      # Both keys below belong to the INPUT PLUGIN, which reads /etc/bluetooth/input.conf
      # (group [General]) — confirmed against bluez 5.86, whose bluetoothd carries the
      # literals `input.conf: UserspaceHID=%s` / `input.conf: ClassicBondedOnly=%s`. Kept in
      # main.conf they were not merely noisy, they were silently INERT. `hardware.bluetooth.input`
      # is the option that writes input.conf, so they now actually take effect.
      settings = {
        General = {
          Experimental = true;
          FastConnectable = true;
          # Better support for modern multi-profile devices
          MultiProfile = "multiple";
        };
      };
      input = {
        General = {
          UserspaceHID = true;
          # Allow connection without permanent bonding if needed
          ClassicBondedOnly = false;
        };
      };
    };

    # Generic Bluetooth management tool (GUI)
    services.blueman.enable = true;
    systemd.user.services.blueman-applet.enable = false;
  };
}
