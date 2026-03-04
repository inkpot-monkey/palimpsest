# Plan
# 1. Replace mopidy with spotifyd
# 2. Test and make sure that is working
# 3. Install volumio
# 4. Get a physical knob
{
  config,
  pkgs,
  ...
}:

{
  hardware.alsa.enablePersistence = true;

  # --- PACKAGES ---
  environment.systemPackages = with pkgs; [
    alsa-utils
    # sox
    # bc
    # pavucontrol
  ];

  # --- SECRETS ---
  sops.secrets."mopidy/config" = {
    owner = "mopidy";
    group = "mopidy";
  };

  # sops.secrets."spotify/password" = {
  #     owner = "spotifyd";
  #     group = "spotifyd";
  #   };

  sops.secrets."last_fm/name" = { };
  sops.secrets."last_fm/api_key" = { };
  sops.secrets."last_fm/secret" = { };
  sops.secrets."last_fm/password" = { };

  # --- USERS for SOPS ---
  # These users must exist before sops-install-secrets runs.
  # users.users.spotifyd = {
  #   isSystemUser = true;
  #   group = "spotifyd";
  #   extraGroups = [ "audio" ];
  # };
  # users.groups.spotifyd = { };

  # --- SERVICES ---
  # services.spotifyd = {
  #   enable = false;
  #   settings = {
  #     global = {
  #       device_name = config.networking.hostName;
  #       backend = "alsa";
  #       device = "hw:0,0";
  #       # mixer = "Digital"; # Allows spotify connect to control the hardware volume
  #       bitrate = 320;
  #       username = "3twskugod0qopz0fr5f3ri22h";
  #       password_cmd = "cat ${config.sops.secrets."spotify/password".path}";

  #       # Auto-pause Mopidy when Spotify starts playing (MoOde Architecture)
  #       onevent = ''
  #         if [ "$PLAYER_EVENT" = "start" ] || [ "$PLAYER_EVENT" = "play" ]; then
  #           ${pkgs.mpc}/bin/mpc -h 127.0.0.1 -p 6600 pause || true
  #         fi
  #       '';
  #     };
  #   };
  # };

  users.users.mopidy = {
    isSystemUser = true;
    group = "mopidy";
    extraGroups = [ "audio" ];
  };
  users.groups.mopidy = { };

  services.mopidy = {
    enable = true;
    extensionPackages = [
      pkgs.mopidy-iris
      # pkgs.mopidy-spotify
      # pkgs.mopidy-local
      pkgs.mopidy-tunein
      pkgs.mopidy-scrobbler
      pkgs.mopidy-mpd
    ];

    extraConfigFiles = [ config.sops.secrets."mopidy/config".path ];

    settings = {
      core = {
        restore_state = true;
      };
      iris = {
        enabled = true;
        country = "US";
        locale = "en_US";
      };
      scrobbler = {
        enabled = true;
        username = "_FILE_${config.sops.secrets."last_fm/name".path}";
        password = "_FILE_${config.sops.secrets."last_fm/password".path}";
      };
      http = {
        enabled = true;
        hostname = "0.0.0.0";
        port = 6680;
        zeroconf = "Mopidy HTTP Server on ${config.networking.hostName}";
      };
      mpd = {
        enabled = true;
        hostname = "127.0.0.1";
        port = 6600;
      };
      m3u = {
        enabled = true;
        base_dir = "/var/lib/mopidy/m3u";
        playlists_dir = "${pkgs.linkFarm "mopidy-playlists" [
          {
            name = "radio_france.m3u";
            path = pkgs.writeText "radio_france.m3u" ''
              #EXTM3U
              #EXTINF:-1,FIP
              https://stream.radiofrance.fr/fip/fip.m3u8?id=radiofrance
              #EXTINF:-1,FIP Rock
              https://stream.radiofrance.fr/fiprock/fiprock.m3u8?id=radiofrance
              #EXTINF:-1,FIP Jazz
              https://stream.radiofrance.fr/fipjazz/fipjazz.m3u8?id=radiofrance
              #EXTINF:-1,FIP Groove
              https://stream.radiofrance.fr/fipgroove/fipgroove.m3u8?id=radiofrance
              #EXTINF:-1,FIP World
              https://stream.radiofrance.fr/fipworld/fipworld.m3u8?id=radiofrance
              #EXTINF:-1,FIP Electro
              https://stream.radiofrance.fr/fipelectro/fipelectro.m3u8?id=radiofrance
              #EXTINF:-1,FIP Reggae
              https://stream.radiofrance.fr/fipreggae/fipreggae.m3u8?id=radiofrance
              #EXTINF:-1,FIP Metal
              https://stream.radiofrance.fr/fipmetal/fipmetal.m3u8?id=radiofrance
              #EXTINF:-1,FIP Hip-Hop
              https://stream.radiofrance.fr/fiphiphop/fiphiphop.m3u8?id=radiofrance
            '';
          }
        ]}";
      };
    };
  };

  # Open the firewall for the Web UI
  networking.firewall.allowedTCPPorts = [ 6680 ];
}
