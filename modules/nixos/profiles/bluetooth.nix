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
      settings = {
        General = {
          Experimental = true;
          FastConnectable = true;
          UserspaceHID = true;
          # Better support for modern multi-profile devices
          MultiProfile = "multiple";
        };
        Input = {
          # Allow connection without permanent bonding if needed
          ClassicBondedOnly = false;
        };
      };
    };

    # Generic Bluetooth management tool (GUI)
    services.blueman.enable = true;
  };
}
