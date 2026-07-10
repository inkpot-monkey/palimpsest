# SMTP TLS Reporting (TLSRPT / RFC 8460) → node-exporter textfile metrics.
#
# The TLS-report analogue of the DMARC pipeline. Receivers that enforce your
# MTA-STS/DANE policy mail a daily report of how many TLS sessions to your MX
# SUCCEEDED vs FAILED. Those reports used to fall through postmaster@ to the human
# catch-all; the dns app now routes `_smtp._tls` rua → tlsrpt@ (parts/apps/dns),
# and this profile drains that mailbox into Grafana so they stop hitting the inbox.
#
# Unlike DMARC (XML, parsed by dmarc-metrics-exporter), TLS reports are JSON and
# nothing in nixpkgs consumes them, so a small stdlib poller (tlsrpt-poll.py) does
# it: IMAP-poll → parse → write cumulative counters to the node-exporter textfile
# collector dir. No new scrape job — the existing `node` job already scrapes them.
# The white-box failure alert is the sibling profile monitoring-tlsrpt-alert.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-tlsrpt;
  user = "monitoring-tlsrpt";
in
{
  options.custom.profiles.monitoring-tlsrpt = {
    enable = lib.mkEnableOption ''
      the TLSRPT (SMTP TLS Reporting) poller. Polls the `tlsrpt` mailbox on
      Stalwart via IMAP and writes smtp_tls_report_* metrics to the node-exporter
      textfile directory. Enable on the monitoring host (rk1b), alongside
      custom.profiles.monitoring-dmarc.
    '';

    imapUser = lib.mkOption {
      type = lib.types.str;
      default = "tlsrpt";
      description = ''
        IMAP login for the TLS-report mailbox. Like the `dmarc` account, Stalwart
        authenticates by account NAME, not address — so this is the bare principal
        (the `tlsrpt` account owns tlsrpt@<domain> across all mail domains).
      '';
    };

    imapHost = lib.mkOption {
      type = lib.types.str;
      default = "mail.palebluebytes.space";
      description = ''
        Stalwart IMAP endpoint. The poller runs on rk1b, not the mail host, so this
        can't be localhost; `mail.palebluebytes.space` resolves to kelpy's tailnet
        IP (networking.hosts) and matches the cert on the 993 implicit-TLS listener.
      '';
    };

    imapPort = lib.mkOption {
      type = lib.types.port;
      default = 993;
      description = "Stalwart IMAP port (SSL/TLS implicit).";
    };

    mailbox = lib.mkOption {
      type = lib.types.str;
      default = "INBOX";
      description = "IMAP mailbox (folder) the tlsrpt account receives reports in.";
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "node-exporter textfile collector directory (see monitoring-exporters).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.tlsrpt_imap_password = {
      # Lives in monitoring.yaml (rk1b-readable) rather than mail.yaml (kelpy-only),
      # so the poller host is never handed the Stalwart admin secret. Mirrors
      # dmarc_imap_password.
      sopsFile = self.lib.getSecretPath "profiles/monitoring.yaml";
      owner = user;
      group = user;
    };

    users.users.${user} = {
      isSystemUser = true;
      group = user;
      # Supplementary node-exporter group so the poller can write into the 0775
      # textfile dir owned by node-exporter (see monitoring-exporters tmpfiles rule).
      extraGroups = [ "node-exporter" ];
      description = "TLSRPT metrics poller";
    };
    users.groups.${user} = { };

    systemd.services.monitoring-tlsrpt-poll = {
      description = "Poll the tlsrpt mailbox and export SMTP TLS report metrics (RFC 8460)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        TLSRPT_IMAP_HOST = cfg.imapHost;
        TLSRPT_IMAP_PORT = toString cfg.imapPort;
        TLSRPT_IMAP_USER = cfg.imapUser;
        TLSRPT_IMAP_PASSWORD_FILE = config.sops.secrets.tlsrpt_imap_password.path;
        TLSRPT_MAILBOX = cfg.mailbox;
        TLSRPT_STATE_DIR = "/var/lib/${user}";
        TLSRPT_METRICS_FILE = "${cfg.metricsDir}/tlsrpt.prom";
      };

      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = user;
        StateDirectory = user;
        StateDirectoryMode = "0700";
        ExecStart = "${pkgs.python3}/bin/python3 ${./tlsrpt-poll.py}";

        # Hardening (mirrors dmarc-metrics-exporter). ProtectSystem=strict makes /var
        # read-only, so the textfile dir must be granted explicitly — the poller writes
        # its .prom there, not into StateDirectory.
        ReadWritePaths = [ cfg.metricsDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectControlGroups = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
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

    systemd.timers.monitoring-tlsrpt-poll = {
      description = "Hourly TLSRPT mailbox poll";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true; # catch up a missed run at next boot
        RandomizedDelaySec = "10m";
      };
    };

    # Persist cumulative counters across rebuilds/reboots so `increase()` ranges and
    # the failure-alert baseline don't reset. A wipe is non-fatal (the alert
    # rebaselines on a counter reset), but persisting avoids gaps on the board.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [ "/var/lib/${user}" ];
    };
  };
}
