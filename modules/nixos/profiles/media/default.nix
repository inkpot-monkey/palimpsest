{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.media;

  subtitler = pkgs.writeShellApplication {
    name = "auto-sub";
    runtimeInputs = with pkgs; [
      ffmpeg
      jq
      netcat
      file
    ];
    text = builtins.readFile (
      pkgs.replaceVars ./auto-sub.sh {
        TRANSCRIPTION_SERVER_ADDRESS = cfg.transcriptionServer.address;
        TRANSCRIPTION_SERVER_PORT = toString cfg.transcriptionServer.port;
        LANGUAGE = cfg.language;
      }
    );
  };
in
{
  imports = [
    ../../services/stump
  ];

  options.custom.profiles.media = {
    enable = lib.mkEnableOption "Media server and automation configuration";
    transcriptionServer = {
      address = lib.mkOption {
        type = lib.types.str;
        default = "100.x.y.z";
        description = "The IP address of the transcription server.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 9999;
        description = "The port of the transcription server.";
      };
    };
    language = lib.mkOption {
      type = lib.types.str;
      default = "spa";
      description = "The language of the audio track to transcribe.";
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
    services.stump = {
      enable = true;
      openFirewall = true;
    };

    systemd.tmpfiles.rules = [
      "Z /var/cache/jellyfin 0750 jellyfin jellyfin - -"
      "d /var/lib/jellyfin 0700 jellyfin jellyfin -"
    ];

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
      config = lib.mkDefault (
        builtins.readFile (
          pkgs.replaceVars ./flexget.yaml {
            TRANSMISSION_HOST = cfg.transmission.host;
            TRANSMISSION_PORT = toString cfg.transmission.port;
            MEDIA_PATH = toString cfg.mediaPath;
            TASKSPOOLER_BIN = "${pkgs.taskspooler}/bin/tsp";
            AUTOSUB_BIN = "${subtitler}/bin/auto-sub";
            TRANSCRIPTION_SERVER_ADDRESS = cfg.transcriptionServer.address;
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

    # --- 5. Global Packages ---
    environment.systemPackages = with pkgs; [
      flexget
      taskspooler
    ];
  };
}
