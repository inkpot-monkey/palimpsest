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

    room = lib.mkOption {
      type = lib.types.str;
      example = "#aionui-alerts:matrix.example.com";
      description = ''
        Target room — a room alias (created automatically if missing) or a room
        id (`!…`). Aliases are recommended: the notifier resolves them and
        creates the room (inviting {option}`inviteUser`) on first run.
      '';
    };

    botUser = lib.mkOption {
      type = lib.types.str;
      default = "aionui-notifier";
      description = "Matrix bot user localpart. Logged in (or registered) at runtime.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = "File with the bot's password (e.g. a sops secret). Used to log in / register.";
      example = "/run/secrets/aionui_matrix_bot_password";
    };

    registrationTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional homeserver registration token file. If set, the notifier
        self-registers the bot on first run when it does not yet exist.
      '';
    };

    inviteUser = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "@me:matrix.example.com";
      description = "User invited when the notifier creates the room from an alias.";
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
        MATRIX_ROOM = cfg.room;
        MATRIX_USER = cfg.botUser;
        MATRIX_PASSWORD_FILE = cfg.passwordFile;
        MATRIX_INVITE = cfg.inviteUser;
        STATE_DIR = cfg.stateDir;
        POLL_INTERVAL = toString cfg.pollInterval;
      }
      // lib.optionalAttrs (cfg.registrationTokenFile != null) {
        MATRIX_REGISTRATION_TOKEN_FILE = cfg.registrationTokenFile;
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
