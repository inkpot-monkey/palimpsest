{
  config,
  lib,
  pkgs,
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
          # NB: no `i2s = "on"` here — the hifiberry-dacplusadcpro overlay below
          # enables I²S itself, so the base param is redundant (and is a known
          # master-mode DAI-format conflict source). Leave it out.
        };
        dt-overlays = {
          # I²S MASTER mode (the overlay default): params empty so the HAT's
          # onboard oscillators clock the bus. This is the "Pro" board's intended
          # mode and the fix (confirmed 2026-07-05) for the intermittent
          # silent-wedge — in slave mode the Pi synthesised the I²S clock with a
          # jitter-prone fractional divider and the clock block would wedge (brief
          # puff, then silence, recoverable only by a cold power-cycle). Contrary
          # to an earlier assumption, master mode opens the PCM fine here (no
          # -EINVAL). Reverting to `params = { slave = { enable = true; }; }`
          # restores the known-good but wedge-prone slave mode — see
          # hosts/porcupineFish/RUNBOOK-audio-silence.md before changing this.
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

    # Save/restore the DAC's hardware mixer state (e.g. the "Digital" level
    # spotifyd drives) across reboots. This is a hardware-audio concern, so it
    # lives with the card profile rather than the spotifyd profile.
    hardware.alsa.enablePersistence = true;

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

    # Hardware audio tooling: i2c-tools (i2cdetect for the codecs) and alsa-utils
    # (amixer/aplay/speaker-test). Debugging the card needs these regardless of
    # whether spotifyd is running, so they belong with the hardware profile.
    environment.systemPackages = [
      pkgs.i2c-tools
      pkgs.alsa-utils
    ];
  };
}
