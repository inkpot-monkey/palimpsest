{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.audio;
in
{
  options.custom.profiles.audio = {
    enable = lib.mkEnableOption "audio configuration (PipeWire)";
  };

  config = lib.mkIf cfg.enable {
    # 1. Disable PulseAudio (standard for PipeWire)
    services.pulseaudio.enable = false;
    security.rtkit.enable = true;

    # 2. Enable PipeWire and refined settings
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      alsa.support32Bit = true;
      pulse.enable = true;
      jack.enable = true;

      # High-quality resampling and low-latency tuning
      extraConfig.pipewire."99-low-latency" = {
        "context.properties" = {
          "default.clock.rate" = 48000;
          "default.clock.quantum" = 1024;
          "default.clock.min-quantum" = 32;
          "default.clock.max-quantum" = 8192;
        };
      };


      # Wireplumber configuration
      wireplumber.enable = true;
      wireplumber.extraConfig = {
        "10-disable-camera" = {
          "wireplumber.profiles" = {
            main = {
              "monitor.libcamera" = "disabled";
            };
          };
        };
        "11-bluetooth-policy" = {
          "wireplumber.settings" = {
            "bluetooth.autoswitch-to-headset-profile" = false;
          };
        };
      };
    };

    # Audio management tools
    environment.systemPackages = with pkgs; [
      pavucontrol # GUI Mixer
      alsa-utils # CLI tools (aplay, arecord, amixer)
    ];
  };
}
