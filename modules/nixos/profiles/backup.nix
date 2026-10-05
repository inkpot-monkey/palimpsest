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

  # Publishes `backup_restic_enabled{restic_job}` for every job this host reports, from the
  # CONFIG (not from a running restic), so the Backups board can draw an off-site edge as
  # a known-disabled state rather than as missing data — the whole reason it survives the
  # jobs being switched off. A separate last-success file (stamped by the restic unit on
  # success, below) carries the freshness; keeping them in different files means a
  # disabled job still shows its last real success age next to enabled=0.
  #
  # The label is `restic_job`, NOT `job`: `job` is a RESERVED Prometheus label (the scrape
  # job name), so a textfile `job="daily"` is silently overwritten to `job="node"` at
  # scrape time — every host's jobs would collapse into one. Do not rename it back.
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
      emit 'backup_restic_enabled{restic_job="${job}"} ${if jobEnabled job then "1" else "0"}'
    '') cfg.reportJobs}

    emit '# HELP backup_restic_check_timestamp_seconds Unix time this backup status check last ran.'
    emit '# TYPE backup_restic_check_timestamp_seconds gauge'
    emit "backup_restic_check_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"

    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/backup-restic-status.prom"
  '';

  # Stamps a single `<metric>{restic_job}` gauge into the textfile dir. Generalised from the
  # original last-success stamp so the prune and check units below can report with the same
  # shape — one file per metric per job, so a stale one never shadows a fresh one.
  #
  # Runs as root, like the restic units, so it can write the exporter dir. Best-effort on a
  # host without monitoring-exporters: there is nowhere to publish, and that must never fail
  # a backup.

  # The original last-success stamp, kept at its existing filename and metric so the Backups
  # board keeps its series. ⚠ Its MEANING changes with this commit: prune no longer runs in
  # the backup unit, so ExecStartPost now fires when the BACKUP succeeded, which is what the
  # metric name always claimed. Before, a failed `forget --prune` in the same ExecStart list
  # suppressed it and the board went cold on a night the backup had in fact succeeded.
  # Stamps a single `<metric>{restic_job}` gauge into the textfile dir. Generalised from the
  # last-success stamp below so the prune and check units report with the same shape — one
  # file per metric per job, so a stale file never shadows a fresh one.
  #
  # Runs as root, like the restic units, so it can write the exporter dir. Best-effort on a
  # host without monitoring-exporters: there is nowhere to publish, and that must never fail
  # a backup.
  stampScript =
    {
      name,
      job,
      metric,
      help,
      # A SHELL snippet evaluated INSIDE the generated stamp script — which is a separate
      # process, so it cannot read the caller's variables. To pass a runtime value, use "$1"
      # and give it as an argument; `$ok` would be unbound there (and `set -u` would kill the
      # stamp before it wrote anything). Defaults to now, which is what a "last <thing>"
      # gauge wants.
      value ? null,
    }:
    let
      valueExpr = if value == null then "$(${pkgs.coreutils}/bin/date +%s)" else value;
    in
    pkgs.writeShellScript "backup-restic-stamp-${name}-${job}" ''
      set -u
      metrics_dir=${lib.escapeShellArg cfg.metricsDir}
      [ -d "$metrics_dir" ] || exit 0
      tmp="$(${pkgs.coreutils}/bin/mktemp "$metrics_dir/.backup-restic-${name}-${job}.XXXXXX")"
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
      {
        printf '%s\n' '# HELP ${metric} ${help}'
        printf '%s\n' '# TYPE ${metric} gauge'
        printf '${metric}{restic_job="%s"} %s\n' "${job}" "${valueExpr}"
      } > "$tmp"
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/backup-restic-${name}-${job}.prom"
    '';

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
        printf 'backup_restic_last_success_timestamp_seconds{restic_job="%s"} %s\n' "${job}" "$(${pkgs.coreutils}/bin/date +%s)"
      } > "$tmp"
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/backup-restic-${job}-lastsuccess.prom"
    '';

  # Everything the out-of-band prune and check units need to talk to the same repository the
  # backup unit uses. Derived from the same secrets rather than restated, so a rotation or a
  # repository move cannot leave these two pointing somewhere else.
  resticEnv = job: {
    RESTIC_PASSWORD_FILE = config.sops.secrets.restic_password.path;
    RESTIC_REPOSITORY_FILE = config.sops.templates."restic-repo".path;
    # One cache per job, matching what the nixpkgs module does. restic keys its cache by
    # repository ID internally so sharing would be safe, but a separate directory also keeps
    # one job's cache eviction out of another's way.
    RESTIC_CACHE_DIR = "/var/cache/restic-backups-${job}";
  };

  resticBin = "${lib.getExe pkgs.restic} -o ${sftpCommand}";

  # PRUNE, OUT OF BAND. Deliberately not the nixpkgs module's `pruneOpts`, which appends
  # `unlock` and `forget --prune` to the BACKUP unit's ExecStart list. Two problems with that:
  #
  #   1. ExecStartPost — where the last-success metric is stamped — fires only when every
  #      ExecStart succeeded, so a prune that failed on a contended lock suppressed the
  #      stamp for a backup that had in fact succeeded. The board went cold on a good night.
  #   2. `forget --prune` is the only operation needing an EXCLUSIVE repository lock, and
  #      `--retry-lock` cannot be reached through the module (`extraOptions` entries are all
  #      prefixed `-o `, and `extraBackupArgs` reaches only the `backup` subcommand — see
  #      nixpkgs#468191). Keeping prune on its own timer is therefore the only available way
  #      to stop it contending, which matters more once a second destination exists.
  #
  # `unlock` first, as the module did: it clears STALE locks only (restic's own staleness
  # test), so it cannot stomp a live operation.
  pruneUnits = job: retention: {
    systemd.services."restic-prune-${job}" = {
      description = "restic forget+prune for the ${job} repository";
      environment = resticEnv job;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [
          "${resticBin} unlock"
          "${resticBin} forget --prune ${lib.concatStringsSep " " retention}"
        ];
        ExecStartPost = [
          (stampScript {
            name = "lastprune";
            inherit job;
            metric = "backup_restic_last_prune_timestamp_seconds";
            help = "Unix time of the last successful restic forget+prune for this job.";
          })
        ];
      };
    };
    systemd.timers."restic-prune-${job}" = {
      description = "Weekly restic forget+prune for ${job}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Weekly, not per-backup: `forget --prune` rewrites pack files, so running it on every
        # backup is expensive for no benefit. Retention is `--keep-daily 7`, so a weekly sweep
        # holds at most ~14 days of snapshots — the cost of that slack is a little storage.
        OnCalendar = cfg.pruneCalendar;
        Persistent = true;
        RandomizedDelaySec = "10m";
        Unit = "restic-prune-${job}.service";
      };
    };
  };

  # CHECK. Nothing on this fleet verified a backup before this: the nixpkgs module only runs
  # `check` when `checkOpts` is non-empty (`runCheck` defaults to `checkOpts != []`), and it
  # was never set — so every "successful" backup was unverified. palimpsest#150 asks for
  # exactly this.
  #
  # Its own unit rather than `checkOpts`, for the same reason prune is: `check` would
  # otherwise join the backup unit's ExecStart list, where a transient read error during a
  # multi-hundred-megabyte data read would fail the unit and suppress the backup's own
  # last-success stamp.
  #
  # The script writes the success gauge itself — on both paths — and then exits with restic's
  # status, so a failure is both visible on the board AND fails the unit.
  checkUnits = job: {
    systemd.services."restic-check-${job}" = {
      description = "restic integrity check for the ${job} repository";
      environment = resticEnv job;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "restic-check-${job}" ''
          set -u
          ok=0
          if ${resticBin} check ${lib.concatStringsSep " " cfg.checkOpts}; then ok=1; fi
          ${
            stampScript {
              name = "checksuccess";
              inherit job;
              metric = "backup_restic_check_success";
              help = "Whether the last restic integrity check for this job passed (1) or failed (0).";
              value = "$1";
            }
          } "$ok"
          ${stampScript {
            name = "lastcheck";
            inherit job;
            metric = "backup_restic_last_check_timestamp_seconds";
            help = "Unix time the last restic integrity check for this job ran, pass or fail.";
          }}
          [ "$ok" = 1 ] || exit 1
        '';
      };
    };
    systemd.timers."restic-check-${job}" = {
      description = "Periodic restic integrity check for ${job}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.checkCalendar;
        Persistent = true;
        RandomizedDelaySec = "30m";
        Unit = "restic-check-${job}.service";
      };
    };
  };

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

    pruneCalendar = lib.mkOption {
      type = lib.types.str;
      default = "Sun 04:00";
      description = ''
        When `forget --prune` runs, for every enabled job. Out of band from the backup —
        see the pruneUnits comment for why it is not the module's `pruneOpts`.
      '';
    };

    checkCalendar = lib.mkOption {
      type = lib.types.str;
      default = "Sun 05:30";
      description = ''
        When the integrity check runs. After `pruneCalendar` by default, so a week's
        rewritten pack files are the ones verified rather than the ones prune replaced.
      '';
    };

    checkOpts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "--read-data-subset=10%" ];
      example = [ "--read-data-subset=1/7" ];
      description = ''
        Options for `restic check`. The default verifies repository STRUCTURE plus a random
        tenth of the pack data each run, so the whole repository is covered over ~10 weeks
        while each run downloads only ~a tenth of it.

        A bare structural `check` (`[ ]`) proves the index and metadata are consistent but
        reads no pack data, so it cannot detect bit rot in the packs themselves — which is
        the failure an off-site copy exists to survive. Hence a subset rather than nothing.
        `--read-data` reads everything and costs a full download each run.
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
        # pruneOpts is deliberately EMPTY: retention is enforced by restic-prune-daily on its
        # own timer. Setting it here would weld `unlock` and `forget --prune` into this unit's
        # ExecStart list, which is what made a failed prune suppress the backup's own
        # last-success stamp. Retention itself is unchanged — see `dailyRetention`.
        pruneOpts = [ ];
        extraOptions = [
          # Use a dedicated Restic SSH key; rsync.net's public key is trusted in base.nix.
          # -F /dev/null avoids permission issues with ~/.ssh/config in the Nix store.
          sftpCommand
        ];
      };
      # Stamp last-success after a successful run. ExecStartPost fires only when every
      # ExecStart step succeeded — which, now that prune has moved to its own unit, means
      # exactly "the backup succeeded". Feeds the Backups board's freshness.
      systemd.services.restic-backups-daily.serviceConfig.ExecStartPost = [ (resticStamp "daily") ];
    })

    # Retention and verification for `daily`, each on its own timer. The retention policy is
    # the one that used to live in this job's `pruneOpts` and is unchanged.
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        (pruneUnits "daily" [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ])
        (checkUnits "daily")
      ]
    ))

    # Same pair for `telemetry`, with its shorter retention.
    (lib.mkIf cfg.monitoringTelemetry.enable (
      lib.mkMerge [
        (pruneUnits "telemetry" [ "--keep-daily 7" ])
        (checkUnits "telemetry")
      ]
    ))

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
        # Empty for the same reason as `daily` above; retention lives in restic-prune-telemetry.
        pruneOpts = [ ];
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
