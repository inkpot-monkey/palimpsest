{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.aionui-notifier;
  notifier = pkgs.writers.writePython3Bin "aionui-notifier" {
    flakeIgnore = [
      "E501" # allow lines slightly over 79 chars
      "W503" # line break before binary operator (PEP 8 now prefers this; W504 is its opposite)
    ];
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

    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        File holding the matrix-hookshot generic-webhook URL events are POSTed
        to. hookshot owns the Matrix side (room + formatting). The file may be
        empty initially — it is written by the provisioning service once the
        connection exists; the notifier idles and picks the URL up once present.
      '';
      example = "/var/lib/aionui-notifier/hookshot_webhook_url";
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

    systemd.services.aionui-notifier = {
      description = "AionUi → Matrix notifier";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "aionui.service"
      ];

      environment = {
        AIONUI_URL = cfg.aionuiUrl;
        STATE_DIR = cfg.stateDir;
        POLL_INTERVAL = toString cfg.pollInterval;
        MATRIX_WEBHOOK_URL_FILE = toString cfg.webhookUrlFile;
      };

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        # systemd creates + chowns the (persisted) state dir to User on start.
        StateDirectory = baseNameOf cfg.stateDir;
        StateDirectoryMode = "0750";
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
