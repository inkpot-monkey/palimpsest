{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.hifiberry;
in
{
  options.custom.profiles.hifiberry = {
    enable = lib.mkEnableOption "HiFiBerry hardware support for Raspberry Pi";
  };

  config = lib.mkIf cfg.enable {
    # High-level RPi hardware configuration via nvmd/nixos-raspberrypi
    hardware.raspberry-pi.config = {
      all = {
        base-dt-params = {
          audio = {
            enable = true;
            value = lib.mkForce "off";
          };
          i2c_arm = {
            enable = true;
            value = "on";
          };
          i2s = {
            enable = true;
            value = "on";
          };
        };
        dt-overlays = {
          hifiberry-dacplusadcpro = {
            enable = true;
            params = { };
          };
          disable-bt = {
            enable = true;
            params = { };
          };
        };
      };
    };

    # Standard NixOS hardware settings
    hardware.i2c.enable = true;

    # Explicitly load necessary modules (Safeguard)
    boot.kernelModules = [
      "i2c-dev"
      "i2c-bcm2835"
      "snd-soc-hifiberry-dacplusadcpro"
      "snd-soc-pcm512x-i2c"
      "snd-soc-pcm186x-i2c"
    ];

    # Disable onboard audio to avoid conflicts
    boot.blacklistedKernelModules = [ "snd_bcm2835" ];
  };
}
