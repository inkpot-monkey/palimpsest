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
        };
      };
    };

    # Generic Bluetooth management tool (GUI)
    services.blueman.enable = true;
  };
}
