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
  sops.secrets."spotify/password" = {
    owner = "spotifyd";
    group = "spotifyd";
  };

  sops.secrets."mopidy/config" = {
    owner = "mopidy";
    group = "mopidy";
  };

  # --- USERS for SOPS ---
  # These users must exist before sops-install-secrets runs.
  # users.users.spotifyd = {
  #   isSystemUser = true;
  #   group = "spotifyd";
  #   extraGroups = [ "audio" ];
  # };
  # users.groups.spotifyd = { };

  users.users.mopidy = {
    isSystemUser = true;
    group = "mopidy";
    extraGroups = [ "audio" ];
  };
  users.groups.mopidy = { };

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

  services.mopidy = {
    enable = true;
    # extensionPackages = [
    #   pkgs.mopidy-iris
    #   pkgs.mopidy-spotify
    #   pkgs.mopidy-local
    #   pkgs.mopidy-mpd
    # ];

    # extraConfigFiles = [ config.sops.secrets."mopidy/config".path ];

    # settings = {
    #   core = {
    #     restore_state = true;
    #   };
    #   audio = {
    #     output = "alsasink device=hw:0,0";
    #   };
    #   iris = {
    #     enabled = true;
    #     country = "US";
    #     locale = "en_US";
    #   };
    #   http = {
    #     enabled = true;
    #     hostname = "0.0.0.0";
    #     port = 6680;
    #     zeroconf = "Mopidy HTTP Server on NixHiFi";
    #   };
    #   mpd = {
    #     enabled = true;
    #     hostname = "127.0.0.1";
    #     port = 6600;
    #   };
    # };
  };

  # Open the firewall for the Web UI
  networking.firewall.allowedTCPPorts = [ 6680 ];
}
