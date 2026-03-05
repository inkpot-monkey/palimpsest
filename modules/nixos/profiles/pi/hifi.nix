# Plan
# 1. Install mpd for radio
# 2. Get a physical knob
{
  config,
  pkgs,
  ...
}:

{
  # --- AUDIO STACK (ALSA Direct) ---
  services.pulseaudio.enable = false;

  hardware.alsa.enablePersistence = true;

  # --- PACKAGES ---
  environment.systemPackages = with pkgs; [
    alsa-utils
  ];

  # --- SECRETS ---
  sops.secrets."spotify/password" = {
    owner = "spotifyd";
    group = "spotifyd";
  };

  # sops.secrets."last_fm/name" = { };
  # sops.secrets."last_fm/api_key" = { };
  # sops.secrets."last_fm/secret" = { };
  # sops.secrets."last_fm/password" = { };

  # --- USERS for SOPS ---
  # These users must exist before sops-install-secrets runs.
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
        mixer = "Digital"; # Use hardware mixer for volume control
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
}
