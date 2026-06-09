{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.aionui-notifier;
  notifier = pkgs.writers.writePython3Bin "aionui-notifier" {
    flakeIgnore = [ "E501" ]; # allow lines slightly over 79 chars
  } (builtins.readFile ./notifier.py);
in
{
  options.services.aionui-notifier = {
    enable = lib.mkEnableOption "AionUi → Matrix notifier (polls aioncore, posts agent events)";

    aionuiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:25808";
      description = "Base URL of the AionUi web-host (aioncore /api). Unauthenticated in local mode.";
    };

    matrixUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:6167";
      description = "Base URL of the Matrix homeserver client-server API.";
    };

    roomId = lib.mkOption {
      type = lib.types.str;
      example = "!abcdef:matrix.example.com";
      description = "Matrix room ID the bot posts notifications to.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "File containing the Matrix bot access token (e.g. a sops secret).";
      example = "/run/secrets/aionui_matrix_token";
    };

    pollInterval = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Seconds between polls of the AionUi API.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/aionui-notifier";
      description = "Directory for the notifier's de-dup state.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "aionui-notifier";
      description = "User to run the notifier as.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      description = "Group to run the notifier as.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) group;
      home = cfg.stateDir;
      createHome = false;
      description = "AionUi Matrix notifier service user";
    };
    users.groups.${cfg.group} = { };

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0750 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.aionui-notifier = {
      description = "AionUi → Matrix notifier";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "aionui.service"
      ];

      environment = {
        AIONUI_URL = cfg.aionuiUrl;
        MATRIX_URL = cfg.matrixUrl;
        MATRIX_ROOM = cfg.roomId;
        MATRIX_TOKEN_FILE = cfg.tokenFile;
        STATE_DIR = cfg.stateDir;
        POLL_INTERVAL = toString cfg.pollInterval;
      };

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.getExe notifier;
        Restart = "on-failure";
        RestartSec = "10s";

        # Network-to-localhost only; safe to harden tightly.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.stateDir ];
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
      };
    };
  };
}
