{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.dmarc-metrics-exporter;
in
{
  options.services.dmarc-metrics-exporter = {
    enable = lib.mkEnableOption "DMARC Metrics Exporter";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dmarc-metrics-exporter;
      defaultText = lib.literalExpression "pkgs.dmarc-metrics-exporter";
      description = "The dmarc-metrics-exporter package to use.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "IP address to listen on for scrape requests.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 9797;
      description = "Port to listen on for scrape requests.";
    };

    imap = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "IMAP server hostname.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 993;
        description = "IMAP server port.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        description = "IMAP username.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing IMAP password.";
      };

      mailbox = lib.mkOption {
        type = lib.types.str;
        default = "INBOX";
        description = "IMAP mailbox (folder) to check for reports.";
      };
    };

    pollInterval = lib.mkOption {
      type = lib.types.int;
      default = 3600; # 1 hour
      description = "IMAP poll interval in seconds.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.dmarc-metrics-exporter = {
      description = "DMARC Metrics Exporter";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "stalwart.service"
      ];

      serviceConfig = {
        RuntimeDirectory = "dmarc-metrics-exporter";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "dmarc-metrics-exporter";
        WorkingDirectory = "/var/lib/dmarc-metrics-exporter";

        # Dynamic config file generation in /run to avoid storing the plain IMAP password in /nix/store
        ExecStartPre = pkgs.writeShellScript "dmarc-metrics-exporter-pre" ''
          PASSWORD=$(cat "${cfg.imap.passwordFile}")
          ${pkgs.jq}/bin/jq -n \
            --arg listen_addr "${cfg.listenAddress}" \
            --argjson port ${toString cfg.port} \
            --arg imap_host "${cfg.imap.host}" \
            --argjson imap_port ${toString cfg.imap.port} \
            --arg imap_user "${cfg.imap.user}" \
            --arg imap_password "$PASSWORD" \
            --arg imap_mailbox "${cfg.imap.mailbox}" \
            --argjson poll_interval ${toString cfg.pollInterval} \
            '{
              listen_addr: $listen_addr,
              port: $port,
              imap: {
                host: $imap_host,
                port: $imap_port,
                user: $imap_user,
                password: $imap_password,
                mailbox: $imap_mailbox
              },
              poll_interval_seconds: $poll_interval,
              storage_path: "/var/lib/dmarc-metrics-exporter"
            }' \
            > /run/dmarc-metrics-exporter/config.json
          chmod 600 /run/dmarc-metrics-exporter/config.json
        '';

        ExecStart = "${cfg.package}/bin/dmarc-metrics-exporter --configuration /run/dmarc-metrics-exporter/config.json";
        Restart = "always";
        RestartSec = "10s";

        # Hardening & Sandboxing
        User = "dmarc-metrics-exporter";
        Group = "dmarc-metrics-exporter";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        PrivateUsers = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectControlGroups = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        MemoryDenyWriteExecute = true;
        LockPersonality = true;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
      };
    };

    users.users.dmarc-metrics-exporter = {
      isSystemUser = true;
      group = "dmarc-metrics-exporter";
      description = "DMARC Metrics Exporter service user";
    };

    users.groups.dmarc-metrics-exporter = { };
  };
}
