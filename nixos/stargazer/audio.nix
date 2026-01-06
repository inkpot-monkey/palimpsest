{ ... }:
{
  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
    # use the example session manager (no longer necessary in recent NixOS, but good to be explicit or use wireplumber)
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
      # Workaround for Framework 13 AMD microphone issues (crackle/silence)
      # Disabling UCM allows fallback to the robust "Analog Stereo Duplex" profile
      "10-disable-ucm" = {
        "wireplumber.settings" = {
          "alsa.use-ucm" = false;
        };
      };
    };
  };
}
