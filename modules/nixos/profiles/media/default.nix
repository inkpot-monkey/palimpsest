{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.media;

in
{
  imports = [
    # ../../services/stump
  ];

  options.custom.profiles.media = {
    enable = lib.mkEnableOption "Media server and automation configuration";
    language = lib.mkOption {
      type = lib.types.str;
      default = "spa";
      description = "The language of the subtitles to download.";
    };
    transmission = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "The hostname of the Transmission server.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 9091;
        description = "The port of the Transmission server.";
      };
    };
    mediaPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/media";
      description = "The base path for media storage.";
    };
    testMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable test mode (mock secrets).";
    };
  };

  config = lib.mkIf cfg.enable {
    # --- 1. Impermanence & State Preservation ---
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      hideMounts = true;
      directories = [
        "/var/lib/jellyfin"
        "/var/cache/jellyfin"
        "/var/lib/flexget"
        "/var/lib/stump"
        "${cfg.mediaPath}"
      ];
    };

    # --- 2. Jellyfin Core Service ---
    services.jellyfin = {
      enable = true;
      openFirewall = true;
    };

    users.users.jellyfin.extraGroups = [ "render" ];

    # --- 3. Stump Media Server ---
    # services.stump = {
    #   enable = true;
    #   openFirewall = true;
    # };

    systemd.tmpfiles.rules = [
      "Z /var/cache/jellyfin 0750 jellyfin jellyfin - -"
      "Z /var/lib/jellyfin 0700 jellyfin jellyfin - -"
      "d ${cfg.mediaPath}/movies 0755 flexget jellyfin - -"
      "d ${cfg.mediaPath}/series 0755 flexget jellyfin - -"
    ];

    # Ensure media directories exist before flexget starts
    systemd.services.media-dirs = {
      description = "Create media directories";
      before = [ "flexget.service" ];
      wantedBy = [ "flexget.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
      };
      script = ''
        mkdir -p "${cfg.mediaPath}/movies" "${cfg.mediaPath}/series"
        chown flexget:jellyfin "${cfg.mediaPath}/movies" "${cfg.mediaPath}/series"
      '';
    };

    # --- 3. FlexGet Automation Engine ---
    sops.secrets.flexget_webui_password = lib.mkIf (!cfg.testMode) {
      sopsFile = self.lib.getSecretFile "media";
      key = "flexget/password";
      owner = "flexget";
    };

    services.flexget = {
      enable = true;
      user = "flexget";
      homeDir = "/var/lib/flexget";
      systemScheduler = true;
      interval = "5m";
      package = pkgs.flexget.overrideAttrs (old: {
        propagatedBuildInputs = old.propagatedBuildInputs ++ [
          pkgs.python3Packages.subliminal
        ];
      });
      config = lib.mkDefault (
        builtins.readFile (
          pkgs.replaceVars ./flexget.yaml {
            TRANSMISSION_HOST = cfg.transmission.host;
            TRANSMISSION_PORT = toString cfg.transmission.port;
            MEDIA_PATH = toString cfg.mediaPath;
            SUBTITLE_LANG = cfg.language;
          }
        )
      );
    };

    systemd.services.flexget-password-setup = {
      description = "Set FlexGet WebUI password";
      before = [ "flexget.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "flexget";
        Group = "jellyfin";
        StateDirectory = "flexget";
        RemainAfterExit = true;
      };
      script = ''
        if [ -f "${config.sops.secrets.flexget_webui_password.path}" ]; then
          mkdir -p /var/lib/flexget
          if [ ! -f /var/lib/flexget/flexget.yml ]; then
            echo "tasks: {}" > /var/lib/flexget/flexget.yml
          fi
          ${pkgs.flexget}/bin/flexget -c /var/lib/flexget/flexget.yml web passwd "$(cat ${config.sops.secrets.flexget_webui_password.path})"
        fi
      '';
    };

    # --- 4. System Permissions ---
    users.users.flexget = {
      isSystemUser = true;
      group = "jellyfin";
    };

    systemd.services.flexget.serviceConfig = {
      StateDirectory = lib.mkForce "flexget media";
    };

    environment.systemPackages = with pkgs; [
      flexget
    ];
  };
}
