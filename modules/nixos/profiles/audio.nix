{ ... }:

{
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
      # Workaround for certain microphones (e.g. Framework 13 AMD)
      # Disabling UCM allows fallback to the robust "Analog Stereo Duplex" profile
      "10-disable-ucm" = {
        "wireplumber.settings" = {
          "alsa.use-ucm" = false;
        };
      };
    };
  };
}
