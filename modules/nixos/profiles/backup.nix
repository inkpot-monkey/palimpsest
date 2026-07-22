{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.backup;
  sftpCommand = "sftp.command='ssh -F /dev/null -i ${config.sops.secrets.restic_ssh_private.path} zh2046@zh2046.rsync.net -s sftp'";

  # A restic job's enabled state, mapped from the profile's two toggles.
  jobEnabled =
    job:
    if job == "daily" then
      cfg.enable
    else if job == "telemetry" then
      cfg.monitoringTelemetry.enable
    else
      false;

  # Publishes `backup_restic_enabled{job}` for every job this host reports, from the
  # CONFIG (not from a running restic), so the Backups board can draw an off-site edge as
  # a known-disabled state rather than as missing data — the whole reason it survives the
  # jobs being switched off. A separate last-success file (stamped by the restic unit on
  # success, below) carries the freshness; keeping them in different files means a
  # disabled job still shows its last real success age next to enabled=0.
  statusScript = pkgs.writeShellScript "backup-restic-status" ''
    set -u
    metrics_dir=${lib.escapeShellArg cfg.metricsDir}
    if [ ! -d "$metrics_dir" ]; then
      # Best-effort, like the git-annex exporter: a host without monitoring-exporters has
      # nowhere to publish. Never fail over it.
      echo "backup-restic-status: metrics dir $metrics_dir absent — skipping" >&2
      exit 0
    fi
    tmp="$(${pkgs.coreutils}/bin/mktemp "$metrics_dir/.backup-restic-status.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
    emit() { printf '%s\n' "$1" >> "$tmp"; }

    emit '# HELP backup_restic_enabled Whether this restic backup job is currently enabled (1) or intentionally off (0).'
    emit '# TYPE backup_restic_enabled gauge'
    ${lib.concatMapStringsSep "\n" (job: ''
      emit 'backup_restic_enabled{job="${job}"} ${if jobEnabled job then "1" else "0"}'
    '') cfg.reportJobs}

    emit '# HELP backup_restic_check_timestamp_seconds Unix time this backup status check last ran.'
    emit '# TYPE backup_restic_check_timestamp_seconds gauge'
    emit "backup_restic_check_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"

    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/backup-restic-status.prom"
  '';

  # Stamps `backup_restic_last_success_timestamp_seconds{job}` — wired as ExecStartPost on
  # the restic unit, so it runs ONLY after a backup actually succeeds and the file then
  # persists across later failures (a broken backup keeps showing its last real success,
  # not nothing). Runs as root, like the restic unit, so it can write the exporter dir.
  resticStamp =
    job:
    pkgs.writeShellScript "backup-restic-stamp-${job}" ''
      set -u
      metrics_dir=${lib.escapeShellArg cfg.metricsDir}
      [ -d "$metrics_dir" ] || exit 0
      tmp="$(${pkgs.coreutils}/bin/mktemp "$metrics_dir/.backup-restic-${job}-lastsuccess.XXXXXX")"
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
      {
        printf '%s\n' '# HELP backup_restic_last_success_timestamp_seconds Unix time of the last successful restic backup for this job.'
        printf '%s\n' '# TYPE backup_restic_last_success_timestamp_seconds gauge'
        printf 'backup_restic_last_success_timestamp_seconds{job="%s"} %s\n' "${job}" "$(${pkgs.coreutils}/bin/date +%s)"
      } > "$tmp"
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/backup-restic-${job}-lastsuccess.prom"
    '';
in
{
  options.custom.profiles.backup = {
    enable = lib.mkEnableOption "daily restic backups configuration";

    monitoringTelemetry = {
      enable = lib.mkEnableOption "VictoriaMetrics snapshot backup to rsync.net (every 6h, keep 7d)";
    };

    reportJobs = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "daily"
          "telemetry"
        ]
      );
      default = [ ];
      example = [ "daily" ];
      description = ''
        restic jobs whose status this host publishes to the Backups board — the set of
        off-site backup jobs this host is RESPONSIBLE for, independent of whether they are
        currently enabled. A host that does off-site backup lists its jobs here so a
        disabled job still surfaces as a known-off edge (backup_restic_enabled = 0) rather
        than vanishing. Publishes only where monitoring-exporters provides the textfile dir.
      '';
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "node-exporter textfile collector directory the status/last-success metrics are written to.";
    };
  };

  config = lib.mkMerge [
    # Restic secrets: shared by daily backup and monitoring telemetry backup.
    # Loaded whenever either is enabled.
    (lib.mkIf (cfg.enable || cfg.monitoringTelemetry.enable) {
      sops.secrets.restic_password = {
        key = "restic/password";
        sopsFile = self.lib.getSecretFile "restic";
      };
      sops.secrets.restic_repo = {
        key = "restic/repo";
        sopsFile = self.lib.getSecretFile "restic";
      };
      sops.secrets.restic_ssh_private = {
        key = "restic/ssh/private";
        sopsFile = self.lib.getSecretFile "restic";
      };

      sops.templates."restic-repo".content = ''
        ${config.sops.placeholder.restic_repo}:backups
      '';
    })

    # Restic status metrics for the Backups board. Emitted whenever this host claims any
    # off-site job, ENABLED OR NOT, so a switched-off job stays visible as a disabled edge.
    (lib.mkIf (cfg.reportJobs != [ ]) {
      systemd.services.backup-restic-status = {
        description = "Publish restic backup status metrics (Backups board)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = statusScript;
        };
      };
      systemd.timers.backup-restic-status = {
        description = "Periodic restic backup status metric refresh";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "5min";
          AccuracySec = "10s";
          Unit = "backup-restic-status.service";
        };
      };
    })

    # Daily service-state backup.
    (lib.mkIf cfg.enable {
      services.restic.backups.daily = {
        initialize = true;
        passwordFile = config.sops.secrets.restic_password.path;
        repositoryFile = config.sops.templates."restic-repo".path;
        timerConfig = {
          OnCalendar = "00/6:00";
          Persistent = true;
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
        extraOptions = [
          # Use a dedicated Restic SSH key; rsync.net's public key is trusted in base.nix.
          # -F /dev/null avoids permission issues with ~/.ssh/config in the Nix store.
          sftpCommand
        ];
      };
      # Stamp last-success on the textfile dir after a successful run (ExecStartPost only
      # fires when every ExecStart step succeeded). Feeds the Backups board's freshness.
      systemd.services.restic-backups-daily.serviceConfig.ExecStartPost = [ (resticStamp "daily") ];
    })

    # Telemetry backup: VictoriaMetrics consistent snapshot → rsync.net every 6h.
    # Uses VM's /snapshot/create API so the backup is always consistent; local
    # snapshots are deleted after each successful backup (restic deduplicates).
    # RPO ≈ 6h. See ADR-0021.
    (lib.mkIf cfg.monitoringTelemetry.enable {
      services.restic.backups.telemetry = {
        initialize = true;
        passwordFile = config.sops.secrets.restic_password.path;
        repositoryFile = config.sops.templates."restic-repo".path;
        timerConfig = {
          OnCalendar = "00/6:00";
          Persistent = true;
        };
        pruneOpts = [ "--keep-daily 7" ];
        extraOptions = [ sftpCommand ];
        paths = [ "/var/cache/victoriametrics/snapshots" ];
        backupPrepareCommand = ''
          ${pkgs.curl}/bin/curl -sf http://localhost:8428/snapshot/create >/dev/null
        '';
        backupCleanupCommand = ''
          ${pkgs.curl}/bin/curl -sf http://localhost:8428/snapshot/deleteAll >/dev/null || true
        '';
      };
      systemd.services.restic-backups-telemetry.serviceConfig.ExecStartPost = [
        (resticStamp "telemetry")
      ];
    })
  ];
}
