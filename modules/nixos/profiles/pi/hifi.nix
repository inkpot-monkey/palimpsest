{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.hifi;
in
{
  options.custom.profiles.hifi = {
    enable = lib.mkEnableOption "High-fidelity audio (Spotifyd) configuration for Raspberry Pi";
  };

  config = lib.mkIf cfg.enable {
    # --- AUDIO STACK (ALSA Direct) ---
    services.pulseaudio.enable = false;

    hardware.alsa.enablePersistence = true;

    # --- PACKAGES ---
    environment.systemPackages = with pkgs; [
      alsa-utils
    ];

    # --- SECRETS ---
    sops.secrets."spotify/password" = {
      sopsFile = self.lib.getSecretPath "profiles/media.yaml";
      owner = "spotifyd";
      group = "spotifyd";
    };

    # --- USERS for SOPS ---
    users.users.spotifyd = {
      isSystemUser = true;
      group = "spotifyd";
      extraGroups = [ "audio" ];
    };
    users.groups.spotifyd = { };

    # --- SERVICES ---
    services.spotifyd = {
      enable = true;
      settings = {
        global = {
          username = "ch0p_";
          password_cmd = "cat ${config.sops.secrets."spotify/password".path}";
          backend = "alsa";
          device = "hw:sndrpihifiberry";
          # Drive the PCM512x's hardware "Digital" mixer with a dB-aware curve.
          # WITHOUT volume_controller = "alsa", spotifyd silently falls back to its
          # *software* controller (logged as `softvol ... Log(60.0)`): a 60 dB curve
          # that sits near-silent until ~70% of the slider, and attenuates digitally
          # (bit-depth loss). "alsa" maps the slider across the DAC's real dB range
          # instead — a human-centric curve at full fidelity. `mixer` is only
          # honoured once the controller is "alsa"; on its own it was a no-op.
          volume_controller = "alsa";
          mixer = "Digital";
          bitrate = 320;
          cache_path = "/var/cache/spotifyd";
          volume_normalisation = true;
          normalisation_pregain = 0; # Increased from -10 to boost volume
          device_type = "speaker";
          device_name = "porcupineFish";
          zeroconf_port = 5354; # Use fixed port for mDNS discovery (not 5353)
          use_mpris = false; # Disable MPRIS to avoid D-Bus crashes on headless system
        };
      };
    };

    # --- FIREWALL ---
    # Open ports for Spotify Connect discovery (mDNS) and streaming
    networking.firewall.allowedTCPPorts = [
      5354 # Spotifyd zeroconf
    ];
    networking.firewall.allowedUDPPorts = [
      5353 # mDNS broadcast
      5354 # Spotifyd zeroconf
    ];
  };
}
