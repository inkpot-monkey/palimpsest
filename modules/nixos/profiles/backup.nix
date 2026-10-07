{
  config,
  lib,
  pkgs,
  self,
  ...
}:

# Off-site restic backups, expressed as a DESTINATION × JOB cross product.
#
# A job says WHAT to back up (`paths`, `exclude`, retention) and is declared by the host that
# owns the data. A destination says WHERE it goes (repository, credentials, transport) and is
# declared here, once, for the whole fleet. Every active pair becomes its own
# `services.restic.backups."<job>-<destination>"` entry, and therefore its own systemd unit,
# timer and metric series.
#
# WHY A CROSS PRODUCT (ADR-0035). One off-site copy is not 3-2-1, and restic cannot write one
# backup run to two repositories. The two available shapes are fan-out (an independent
# `restic backup` per destination, reading the source from local disk) and replication
# (`restic copy` primary→secondary). We fan out, because `restic copy` must DOWNLOAD the whole
# payload before re-uploading it — the repositories use different encryption keys, so the bytes
# cannot move provider-to-provider — and because fan-out yields two repositories that share no
# history, so a bad `forget` or a lapsed account in one cannot propagate to the other.
#
# Adding a second destination is therefore meant to cost one `destinations.<name>` entry and
# nothing else: no host edits, no new units written by hand, no metric plumbing.
let
  cfg = config.custom.profiles.backup;

  # restic stamps its own hostname into every snapshot (Go's os.Hostname), which is this.
  # Used to scope `forget` to THIS host's snapshots — see forgetServices.
  hostName = config.networking.hostName;

  sftpCommand = "sftp.command='ssh -F /dev/null -i ${config.sops.secrets.restic_ssh_private.path} zh2046@zh2046.rsync.net -s sftp'";

  # A restic job's enabled state, mapped from the profile's two toggles. The toggles, not the
  # presence of a `jobs.<name>` entry, decide what runs: a host may declare its paths while
  # backups are still deferred, which is how kelpy and porcupineFish sat for months.
  jobEnabled =
    job:
    if job == "daily" then
      cfg.enable
    else if job == "telemetry" then
      cfg.monitoringTelemetry.enable
    else
      false;

  destinationModule = {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this host sends its jobs to this destination. Off keeps the destination
          VISIBLE on the Backups board as `backup_restic_enabled = 0` rather than letting it
          vanish, which is the distinction that board exists to draw.
        '';
      };

      repository = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/var/lib/restic-local";
        description = "Repository as a literal string. Use `repositoryFile` for anything secret.";
      };

      repositoryFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "File holding the repository string — a sops secret or template.";
      };

      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File of `KEY=value` lines sourced into every unit for this destination. This is how
          an S3-compatible destination receives its credentials, which cannot go in argv or
          the Nix store.
        '';
      };

      passwordFile = lib.mkOption {
        type = lib.types.path;
        default = config.sops.secrets.restic_password.path;
        defaultText = lib.literalExpression "config.sops.secrets.restic_password.path";
        description = "File holding the repository password.";
      };

      extraOptions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "sftp.command='ssh …'" ];
        description = ''
          restic extended options (`-o key=value`), applied to the backup unit AND to this
          destination's forget/prune/check units — a transport the backup needs is a transport
          every other command needs, and splitting them is how maintenance silently stops
          reaching the repository.
        '';
      };

      maintenance = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether THIS host runs the repository-wide maintenance (`prune`, `check`) for this
          destination. Exactly ONE host per destination should set it.

          The fleet's hosts share a single rsync.net repository — snapshots are distinguished
          by restic's own hostname field — so `prune` and `check` are properties of the
          REPOSITORY, not of a host or a job. Two hosts pruning it weekly would contend for
          the same exclusive lock and each repack the same packs; two hosts checking it would
          download the same tenth of the pack data twice. Retention (`forget`) is different
          and runs everywhere: see forgetServices.

          OPT-IN, because the two ways to get this wrong are not equally bad. Defaulting to
          true would mean every host added in phase 3 silently joined the fight over one
          repository's lock; defaulting to false means a brand-new destination with no elected
          maintainer is never verified — which the Backups board shows as a blank Verified
          cell rather than hiding. One is wasteful and invisible, the other is visible.
        '';
      };

      retryLock = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = ''
          `--retry-lock` for the forget and prune units. Both take an EXCLUSIVE repository
          lock (restic's `forget` does so even without `--prune`), so on a shared repository
          they WILL collide; waiting is the correct response, not failing.

          This flag is reachable here only because these units are hand-written. It cannot be
          passed to the module's own backup unit — `extraOptions` entries are each prefixed
          `-o `, and `extraBackupArgs` reaches only the `backup` subcommand (nixpkgs#468191).
        '';
      };

      forgetCalendar = lib.mkOption {
        type = lib.types.str;
        default = "Sun 03:30";
        description = "When retention is applied for this destination's jobs.";
      };

      pruneCalendar = lib.mkOption {
        type = lib.types.str;
        default = "Sun 04:00";
        description = "When `prune` reclaims the space `forget` released. After forgetCalendar.";
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

      settings = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        example = {
          timerConfig = {
            OnCalendar = "04,16:00";
            Persistent = true;
          };
        };
        description = ''
          Extra `services.restic.backups.<job>-<destination>` settings for every job going to
          this destination, applied LAST so it wins over the job's own. The intended use is
          offsetting a second destination's timers off the first's — see the staggering
          assertion below — not overriding `paths`.
        '';
      };
    };
  };

  jobModule = {
    options = {
      paths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          What this job backs up, on every destination. Declared by the host that owns the
          data; an enabled job with no paths is a build error, because restic would succeed
          having backed up nothing.
        '';
      };

      exclude = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Exclude patterns, on every destination.";
      };

      retention = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--keep-daily 7" ];
        description = ''
          `restic forget` keep-policy flags for this job. Applied per destination, scoped to
          this host's own snapshots of this job.
        '';
      };

      timerConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.unspecified;
        default = {
          OnCalendar = "daily";
          Persistent = true;
        };
        description = "When the backup runs. Offset per destination via `destinations.<name>.settings`.";
      };

      notBackedUp = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          "/var/log" = "logs churn nightly and restore nothing anyone wants";
        };
        description = ''
          Persisted directories this job deliberately does NOT back up, each with the reason.
          Documentation with teeth: with `classifyPersistence` set, every persisted directory
          must appear either under `paths` or here, so a path cannot be dropped silently and
          a reason cannot be omitted.

          Keys are absolute paths as `environment.persistence` declares them (so `/var/log`,
          not `/persistent/var/log`). A key that is no longer persisted is a build error, so
          this list cannot rot into a description of a machine that no longer exists.
        '';
      };

      classifyPersistence = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/persistent";
        description = ''
          An `environment.persistence` root whose every declared directory this job must
          CLASSIFY — back up, or decline in `notBackedUp` with a reason.

          This is the whole difference between a targeted backup and a bulk one. `paths = [
          "/persistent" ]` is safe by default and wrong in every other way: it ships logs,
          caches and re-downloadable media off-site, inflates every snapshot, and buries the
          question of what is actually irreplaceable. Enumerating instead makes that question
          explicit — but introduces its own failure, which is that a service added next year
          persists its state and NOBODY NOTICES it is unprotected.

          Setting this closes that hole. Impermanence already declares, exhaustively, every
          directory the host keeps; requiring each one to be classified means adding a service
          FAILS THE BUILD until someone decides whether its state matters. Enumeration with a
          completeness check, rather than enumeration and hope.

          Leave null on a host with no impermanence root (a workstation), where no such
          declaration exists to check against.
        '';
      };

      settings = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        example = {
          backupPrepareCommand = "…";
        };
        description = ''
          Extra `services.restic.backups.<job>-<destination>` settings for this job on every
          destination — `backupPrepareCommand`, `backupCleanupCommand`, `user`, and anything
          else the nixpkgs module takes that this profile does not model.
        '';
      };
    };
  };

  # Roots that are bulk by construction: backing one up means "this whole machine", which is
  # the thing a targeted backup is defined against (ADR-0036). Naming them individually
  # rather than inferring "too shallow" from depth, because the mistake is specific — these
  # are the paths someone reaches for when they want to stop thinking about what matters —
  # and a depth heuristic would reject legitimate paths like /srv/data.
  bulkRoots = [
    "/"
    "/etc"
    "/home"
    "/nix"
    "/persist"
    "/persistent"
    "/root"
    "/srv"
    "/var"
    "/var/cache"
    "/var/lib"
    "/var/log"
  ];

  # THE TARGETING CHECK. Returns the assertions that hold a job's enumeration honest against
  # an impermanence root: every declared directory either backed up or explicitly declined.
  #
  # Deliberately evaluated for EVERY declared job, enabled or not. kelpy and sawtoothShark
  # both carry a job whose backups are still deferred, and a check that only ran once they
  # were switched on would be dormant for exactly the period in which the enumeration is
  # written and then forgotten — the mistake kelpy's own ADR-0031 exclude guard made.
  persistenceAssertions =
    jobName: job:
    let
      root = job.classifyPersistence;
      persistence = config.environment.persistence.${root} or null;

      # Both halves of an impermanence declaration: the system directories and each user's.
      # The user half is easy to forget and is exactly where the interesting judgement calls
      # live (an agent host's checkouts, a workstation's keys), so a check that only read
      # `directories` would quietly exempt them. `dirPath` is impermanence's own absolute
      # path for an entry, which saves re-deriving a home directory it already deduced.
      userDirs = lib.concatMap (u: u.directories or [ ]) (lib.attrValues (persistence.users or { }));
      declared = map (d: d.dirPath) ((persistence.directories or [ ]) ++ userDirs);

      # A directory counts as considered if any backed-up path IS it, CONTAINS it, or is a
      # subtree OF it. The last case is deliberate: backing up only part of a tree is a
      # decision someone made on purpose, and this check is about decisions, not coverage.
      backedUp =
        dir:
        let
          full = root + dir;
        in
        lib.any (p: p == full || lib.hasPrefix "${full}/" p || lib.hasPrefix "${p}/" full) job.paths;

      declined = lib.attrNames job.notBackedUp;
      unclassified = lib.filter (d: !(backedUp d) && !(lib.elem d declined)) declared;
      stale = lib.filter (d: !(lib.elem d declared)) declined;
      contradictory = lib.filter backedUp declined;
    in
    lib.optionals (root != null) [
      {
        assertion = persistence != null;
        message = "custom.profiles.backup.jobs.${jobName}.classifyPersistence = \"${root}\", but environment.persistence has no such root on this host.";
      }
      {
        assertion = unclassified == [ ];
        message = "custom.profiles.backup.jobs.${jobName}: ${toString (lib.length unclassified)} persisted director${
          if lib.length unclassified == 1 then "y is" else "ies are"
        } neither backed up nor declined: ${lib.concatStringsSep ", " unclassified}. This host keeps that state across reboots, so SOMETHING thinks it matters — decide. Add it to `paths` (prefixed ${root}) if losing it would hurt, or to `notBackedUp` with the reason it would not. Do not leave it unclassified: that is how a new service's data ends up protected by nobody.";
      }
      {
        assertion = stale == [ ];
        message = "custom.profiles.backup.jobs.${jobName}.notBackedUp names ${lib.concatStringsSep ", " stale}, which this host no longer persists. Remove the entr${
          if lib.length stale == 1 then "y" else "ies"
        } so the list keeps describing the machine that exists.";
      }
      {
        assertion = contradictory == [ ];
        message = "custom.profiles.backup.jobs.${jobName}: ${lib.concatStringsSep ", " contradictory} is both backed up and listed in `notBackedUp`. One of the two is a mistake.";
      }
    ];

  activeDestinations = lib.filterAttrs (_: d: d.enable) cfg.destinations;
  activeJobs = lib.filterAttrs (name: _: jobEnabled name) cfg.jobs;

  # The cross product, as a flat list of records. Everything below maps over this, so a new
  # destination reaches the backup units, the forget units, the metrics and the board without
  # any of them being touched.
  pairs = lib.concatLists (
    lib.mapAttrsToList (
      jobName: job:
      lib.mapAttrsToList (destName: dest: {
        inherit
          jobName
          job
          destName
          dest
          ;
        name = "${jobName}-${destName}";
      }) activeDestinations
    ) activeJobs
  );

  # Every (job, destination) a host OWNS — the cross product of reportJobs with all declared
  # destinations, enabled or not. This, not `pairs`, is what the Backups board draws from: a
  # disabled job or a switched-off destination must publish `enabled 0` rather than going
  # missing, or "we turned it off" and "the exporter died" look identical.
  reportPairs = lib.concatLists (
    map (
      jobName:
      lib.mapAttrsToList (destName: dest: {
        inherit jobName destName;
        enabled = jobEnabled jobName && dest.enable;
      }) cfg.destinations
    ) cfg.reportJobs
  );

  # Each generated restic job. Precedence runs left to right: this profile's derivation of the
  # pair, then the job's own escape hatch, then the destination's — so a destination can offset
  # timers for everything it receives.
  resticJob =
    p:
    {
      initialize = true;
      inherit (p.dest)
        repository
        repositoryFile
        passwordFile
        environmentFile
        extraOptions
        ;
      inherit (p.job) paths exclude;

      # Tag every snapshot with its job name. This is what makes retention scopable: `forget`
      # considers ALL snapshots in the repository unless filtered ("All snapshots are first
      # divided into groups according to --group-by, and after that the policy ... is applied
      # to each group individually"), and the repository is shared by the whole fleet. Without
      # the tag, `daily`'s keep-policy would be applied to `telemetry`'s snapshot group, and
      # to every other host's.
      extraBackupArgs = [ "--tag ${p.jobName}" ];

      # Deliberately EMPTY. `pruneOpts` welds `unlock` and `forget --prune` into the BACKUP
      # unit's ExecStart list, and ExecStartPost — where the last-success metric is stamped —
      # fires only when every ExecStart step succeeded. A prune failing on a contended lock
      # therefore suppressed the stamp for a backup that had in fact succeeded, and the board
      # went cold on a good night. Retention lives in forgetServices; space reclamation in
      # pruneServices.
      pruneOpts = [ ];

      timerConfig = p.job.timerConfig;
    }
    // p.job.settings
    // p.dest.settings;

  # Renders a Prometheus label set in a FIXED order. `mapAttrsToList` would sort
  # alphabetically, which puts `restic_dest` before `restic_job` and made the status script
  # (whose labels were written out by hand) disagree with the stamps for the same series.
  # Prometheus does not care, but anything matching on the rendered text does — the VM check
  # does, and caught exactly that. Unknown labels are appended rather than dropped.
  renderLabels =
    labels:
    let
      preferred = lib.filter (k: labels ? ${k}) [
        "restic_job"
        "restic_dest"
      ];
      rest = lib.filter (k: !(lib.elem k preferred)) (lib.attrNames labels);
    in
    lib.concatStringsSep "," (map (k: ''${k}="${labels.${k}}"'') (preferred ++ rest));

  # Publishes `backup_restic_enabled{restic_job,restic_dest}` for every job × destination this
  # host owns, from the CONFIG rather than from a running restic — so the Backups board can
  # draw an off-site edge as a known-disabled state instead of as missing data. A separate
  # last-success file (stamped by each restic unit on success) carries the freshness; keeping
  # them in different files means a disabled job still shows its last real success age next to
  # enabled=0.
  #
  # The label is `restic_job`, NOT `job`: `job` is a RESERVED Prometheus label (the scrape job
  # name), so a textfile `job="daily"` is silently overwritten to `job="node"` at scrape time —
  # every host's jobs would collapse into one. Do not rename it back.
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
    ${lib.concatMapStringsSep "\n" (p: ''
      emit 'backup_restic_enabled{${
        renderLabels {
          restic_job = p.jobName;
          restic_dest = p.destName;
        }
      }} ${if p.enabled then "1" else "0"}'
    '') reportPairs}

    emit '# HELP backup_restic_check_timestamp_seconds Unix time this backup status check last ran.'
    emit '# TYPE backup_restic_check_timestamp_seconds gauge'
    emit "backup_restic_check_timestamp_seconds $(${pkgs.coreutils}/bin/date +%s)"

    ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/backup-restic-status.prom"
  '';

  # Stamps a single gauge into the textfile dir — one file per metric per series, so a stale
  # file never shadows a fresh one.
  #
  # Runs as root, like the restic units, so it can write the exporter dir. Best-effort on a
  # host without monitoring-exporters: there is nowhere to publish, and that must never fail
  # a backup.
  stampScript =
    {
      # Filename stem, and the systemd-safe part of the derivation name.
      name,
      # Label set for the series, e.g. { restic_job = "daily"; restic_dest = "rsyncnet"; }.
      labels,
      metric,
      help,
      # A SHELL snippet evaluated INSIDE the generated stamp script — which is a separate
      # process, so it cannot read the caller's variables. To pass a runtime value, use "$1"
      # and give it as an argument; `$ok` would be unbound there (and `set -u` would kill the
      # stamp before it wrote anything). Defaults to now, which is what a "last <thing>" gauge
      # wants.
      value ? null,
    }:
    let
      valueExpr = if value == null then "$(${pkgs.coreutils}/bin/date +%s)" else value;
      labelExpr = renderLabels labels;
    in
    pkgs.writeShellScript "backup-restic-stamp-${name}" ''
      set -u
      metrics_dir=${lib.escapeShellArg cfg.metricsDir}
      [ -d "$metrics_dir" ] || exit 0
      tmp="$(${pkgs.coreutils}/bin/mktemp "$metrics_dir/.backup-restic-${name}.XXXXXX")"
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT
      {
        printf '%s\n' '# HELP ${metric} ${help}'
        printf '%s\n' '# TYPE ${metric} gauge'
        printf '${metric}{${labelExpr}} %s\n' "${valueExpr}"
      } > "$tmp"
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/backup-restic-${name}.prom"
    '';

  # Everything the out-of-band forget, prune and check units need to reach the same repository
  # the backup unit uses. Derived from the destination rather than restated, so a rotation or a
  # repository move cannot leave these pointing somewhere else.
  resticEnv =
    destName: dest:
    {
      RESTIC_PASSWORD_FILE = dest.passwordFile;
      # One cache per destination, shared by that destination's maintenance units. restic keys
      # its cache by repository ID internally, so sharing is safe and lets the week's check
      # reuse the index the prune downloaded.
      RESTIC_CACHE_DIR = "/var/cache/restic-maintenance-${destName}";
    }
    // lib.optionalAttrs (dest.repository != null) { RESTIC_REPOSITORY = dest.repository; }
    // lib.optionalAttrs (dest.repositoryFile != null) {
      RESTIC_REPOSITORY_FILE = dest.repositoryFile;
    };

  # Shared service skeleton for the hand-written maintenance units.
  maintenanceService = destName: dest: {
    environment = resticEnv destName dest;
    # ssh is how the sftp transport works and is NOT on a unit's default PATH; the nixpkgs
    # module puts it there for its own units (`path = [ config.programs.ssh.package ]`) and
    # these need the same, or every command here fails on an sftp destination.
    path = [ config.programs.ssh.package ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      CacheDirectory = "restic-maintenance-${destName}";
      CacheDirectoryMode = "0700";
      PrivateTmp = true;
    }
    // lib.optionalAttrs (dest.environmentFile != null) { EnvironmentFile = dest.environmentFile; };
  };

  resticBin =
    dest: "${lib.getExe pkgs.restic}${lib.concatMapStrings (o: " -o ${o}") dest.extraOptions}";

  # RETENTION, per host × job × destination. Runs EVERYWHERE, unlike prune and check: a
  # snapshot belongs to the host that wrote it, and only that host knows how long to keep it.
  #
  # Scoped with BOTH filters, and both are load-bearing on a repository the fleet shares:
  #   --host  this host's snapshots only, so rk1b's policy cannot expire kelpy's history
  #   --tag   this job's snapshots only, so `daily`'s policy cannot be applied to `telemetry`
  # Without them `forget` considers every snapshot in the repository and applies the policy to
  # each (host, paths) group it finds — which silently makes retention "whichever unit ran
  # last". If the filters ever match nothing, the failure direction is safe: snapshots are
  # kept, not deleted.
  #
  # `--prune` is deliberately NOT passed. Reclaiming space is repository-wide work that one
  # host does for everyone; see pruneServices.
  forgetServices = lib.listToAttrs (
    map (
      p:
      lib.nameValuePair "restic-forget-${p.name}" (
        lib.mkMerge [
          (maintenanceService p.destName p.dest)
          {
            description = "restic retention for ${p.jobName} on ${p.destName}";
            serviceConfig = {
              ExecStart = [
                "${resticBin p.dest} forget --retry-lock ${p.dest.retryLock} --host ${hostName} --tag ${p.jobName} ${lib.concatStringsSep " " p.job.retention}"
              ];
              ExecStartPost = [
                (stampScript {
                  name = "lastforget-${p.name}";
                  labels = {
                    restic_job = p.jobName;
                    restic_dest = p.destName;
                  };
                  metric = "backup_restic_last_forget_timestamp_seconds";
                  help = "Unix time retention was last applied successfully for this job and destination.";
                })
              ];
            };
          }
        ]
      )
    ) pairs
  );

  forgetTimers = lib.listToAttrs (
    map (
      p:
      lib.nameValuePair "restic-forget-${p.name}" {
        description = "Weekly restic retention for ${p.jobName} on ${p.destName}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          # Weekly, not per-backup: retention is `--keep-daily 7`, so a weekly sweep holds at
          # most ~14 days of snapshots, and the cost of that slack is a little storage.
          OnCalendar = p.dest.forgetCalendar;
          Persistent = true;
          # Spread the fleet's exclusive-lock contenders out; --retry-lock covers the rest.
          RandomizedDelaySec = "20m";
          Unit = "restic-forget-${p.name}.service";
        };
      }
    ) pairs
  );

  # The destinations THIS host maintains. `prune` and `check` are repository-wide operations:
  # not scopable to a host or a job, and running them from four hosts would repack and
  # re-download the same data four times while fighting for the same exclusive lock.
  #
  # Filtered from `usedDestinations`, NOT from every enabled destination: a host that sends
  # nothing to a repository has no business pruning it, and declaring the units there would
  # also demand sops secrets it was deliberately never given.
  maintained = lib.filterAttrs (_: d: d.maintenance) usedDestinations;

  # Destinations actually RECEIVING a job on this host. Narrower than `activeDestinations`,
  # which still lists rsync.net on a host whose jobs are all deferred — and there its
  # `repositoryFile` default cannot even be evaluated, because the sops template it points at
  # is only defined when a job is enabled (sops is all-or-nothing per host, so a host that
  # does not back up must not be handed the restic secrets). Validation below therefore covers
  # what is in use, not what is merely declared.
  usedDestinations = lib.filterAttrs (
    name: _: lib.any (p: p.destName == name) pairs
  ) cfg.destinations;

  # SPACE RECLAMATION, per destination, on the elected host.
  #
  # `unlock` first, as the nixpkgs module did: it clears STALE locks only (restic's own
  # staleness test), so it cannot stomp a live operation. Worth keeping — the fleet's first
  # real backup was blocked by a 212-day-old lock left behind by a decommissioned host.
  pruneServices = lib.mapAttrs' (
    destName: dest:
    lib.nameValuePair "restic-prune-${destName}" (
      lib.mkMerge [
        (maintenanceService destName dest)
        {
          description = "restic prune for the ${destName} repository";
          serviceConfig = {
            ExecStart = [
              "${resticBin dest} unlock"
              "${resticBin dest} prune --retry-lock ${dest.retryLock}"
            ];
            ExecStartPost = [
              (stampScript {
                name = "lastprune-${destName}";
                labels.restic_dest = destName;
                metric = "backup_restic_last_prune_timestamp_seconds";
                help = "Unix time this repository was last pruned successfully.";
              })
            ];
          };
        }
      ]
    )
  ) maintained;

  pruneTimers = lib.mapAttrs' (
    destName: dest:
    lib.nameValuePair "restic-prune-${destName}" {
      description = "Weekly restic prune for ${destName}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = dest.pruneCalendar;
        Persistent = true;
        RandomizedDelaySec = "10m";
        Unit = "restic-prune-${destName}.service";
      };
    }
  ) maintained;

  # VERIFICATION, per destination, on the elected host. Nothing on this fleet verified a backup
  # before this existed: the nixpkgs module only runs `check` when `checkOpts` is non-empty
  # (`runCheck` defaults to `checkOpts != [ ]`) and it was never set, so every "successful"
  # backup was unverified. palimpsest#150 asks for exactly this.
  #
  # Its own unit rather than `checkOpts`, for the same reason prune is: `check` would otherwise
  # join the backup unit's ExecStart list, where a transient read error during a
  # multi-hundred-megabyte data read would fail the unit and suppress the backup's own
  # last-success stamp.
  #
  # The script writes the success gauge itself — on BOTH paths — and then exits with restic's
  # status, so a failure is visible on the board AND fails the unit. A check that fails
  # silently is indistinguishable from one that never ran.
  checkServices = lib.mapAttrs' (
    destName: dest:
    lib.nameValuePair "restic-check-${destName}" (
      lib.mkMerge [
        (maintenanceService destName dest)
        {
          description = "restic integrity check for the ${destName} repository";
          serviceConfig.ExecStart = pkgs.writeShellScript "restic-check-${destName}" ''
            set -u
            ok=0
            if ${resticBin dest} check ${lib.concatStringsSep " " dest.checkOpts}; then ok=1; fi
            ${
              stampScript {
                name = "checksuccess-${destName}";
                labels.restic_dest = destName;
                metric = "backup_restic_check_success";
                help = "Whether the last restic integrity check of this repository passed (1) or failed (0).";
                value = "$1";
              }
            } "$ok"
            ${stampScript {
              name = "lastcheck-${destName}";
              labels.restic_dest = destName;
              metric = "backup_restic_last_check_timestamp_seconds";
              help = "Unix time this repository was last checked, pass or fail.";
            }}
            [ "$ok" = 1 ] || exit 1
          '';
        }
      ]
    )
  ) maintained;

  checkTimers = lib.mapAttrs' (
    destName: dest:
    lib.nameValuePair "restic-check-${destName}" {
      description = "Periodic restic integrity check for ${destName}";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = dest.checkCalendar;
        Persistent = true;
        RandomizedDelaySec = "30m";
        Unit = "restic-check-${destName}.service";
      };
    }
  ) maintained;

  # Stamp last-success after a successful run. ExecStartPost fires only when every ExecStart
  # step succeeded — which, now that forget and prune have their own units, means exactly "the
  # backup succeeded". Feeds the Backups board's freshness.
  backupStampServices = lib.listToAttrs (
    map (
      p:
      lib.nameValuePair "restic-backups-${p.name}" {
        serviceConfig.ExecStartPost = [
          (stampScript {
            name = "lastsuccess-${p.name}";
            labels = {
              restic_job = p.jobName;
              restic_dest = p.destName;
            };
            metric = "backup_restic_last_success_timestamp_seconds";
            help = "Unix time of the last successful restic backup for this job and destination.";
          })
        ];
      }
    ) pairs
  );

in
{
  options.custom.profiles.backup = {
    enable = lib.mkEnableOption "daily restic backups configuration";

    monitoringTelemetry = {
      enable = lib.mkEnableOption "VictoriaMetrics snapshot backup to rsync.net (every 6h, keep 7d)";
    };

    destinations = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule destinationModule);
      default = { };
      description = ''
        Off-site repositories every enabled job is sent to, independently (fan-out). The
        `rsyncnet` entry is defined by this profile; a host adds or disables one rather than
        rewriting its jobs.
      '';
    };

    jobs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule jobModule);
      default = { };
      example = lib.literalExpression ''{ daily.paths = [ "/persistent" ]; }'';
      description = ''
        What this host backs up, keyed by job name. Each job is sent to every enabled
        destination, so a host declares its data once and gains the second copy for free.

        Whether a job RUNS is decided by `enable` (daily) and `monitoringTelemetry.enable`
        (telemetry), not by the presence of its entry here — a host may declare its paths
        while backups are still deferred.
      '';
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
        than vanishing. Reported once per declared destination. Publishes only where
        monitoring-exporters provides the textfile dir.
      '';
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "node-exporter textfile collector directory the status/last-success metrics are written to.";
    };
  };

  # ⚠ EVERY PATH IN `config` BELOW IS STATIC, down to the option. That is a hard requirement,
  # not a style: this module both DEFINES `destinations`/`jobs` and READS them to generate its
  # units, so if the module system had to evaluate those options to discover which paths this
  # module defines, it would have to evaluate the definitions to evaluate the definitions.
  # `lib.mkMerge (map … pairs)` as a config entry does exactly that and fails with `infinite
  # recursion encountered`. Computed attrsets belong on the RIGHT of a static path, as
  # `systemd.services = lib.mkMerge [ … ]` — by then the structure question is settled.
  config = lib.mkMerge [
    # The fleet's rsync.net repository, shared by every host (snapshots are told apart by
    # restic's own hostname field). Defined here rather than per host because the credentials
    # are one fleet-wide sops secret; a host opts out with
    # `destinations.rsyncnet.enable = false`, which keeps it visible-but-off on the board.
    {
      custom.profiles.backup.destinations.rsyncnet = {
        repositoryFile = lib.mkDefault config.sops.templates."restic-repo".path;
        extraOptions = lib.mkDefault [
          # A dedicated restic SSH key; rsync.net's host key is trusted in base.nix.
          # -F /dev/null avoids permission issues with ~/.ssh/config in the Nix store.
          sftpCommand
        ];
      };

      # Job defaults. mkDefault throughout: `listOf` merges by CONCATENATION, so a host
      # setting `retention` without this would append to the default rather than replace it,
      # and restic would get two conflicting keep-policies.
      custom.profiles.backup.jobs.daily = {
        retention = lib.mkDefault [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 6"
        ];
        timerConfig = lib.mkDefault {
          # 03:00 and 15:00, NOT 00/6:00. Immich dumps its database at 02:00 and that dump is
          # the only copy of albums, people, faces and EXIF; the old schedule paired a
          # snapshot's files with a dump up to 22h older, so a restore could put assets on
          # disk that the database cannot see. An hour after the dump makes the day's first
          # snapshot an almost-consistent pair. The 15:00 run trades that (a ~13h-old dump)
          # for a 12h file RPO; a restore wanting the consistent pair picks the 03:00 one.
          OnCalendar = "03,15:00";
          Persistent = true;
        };
      };

      # Telemetry: a VictoriaMetrics consistent snapshot, taken via VM's /snapshot/create API
      # so the backup is never torn, and deleted after the run (restic deduplicates, so the
      # next snapshot costs almost nothing). RPO ≈ 6h. See ADR-0021.
      custom.profiles.backup.jobs.telemetry = {
        paths = lib.mkDefault [ "/var/cache/victoriametrics/snapshots" ];
        retention = lib.mkDefault [ "--keep-daily 7" ];
        timerConfig = lib.mkDefault {
          OnCalendar = "00/6:00";
          Persistent = true;
        };
        settings = lib.mkDefault {
          backupPrepareCommand = ''
            ${pkgs.curl}/bin/curl -sf http://localhost:8428/snapshot/create >/dev/null
          '';
          backupCleanupCommand = ''
            ${pkgs.curl}/bin/curl -sf http://localhost:8428/snapshot/deleteAll >/dev/null || true
          '';
        };
      };
    }

    # Restic secrets: shared by every destination that uses them, loaded whenever any job is
    # enabled.
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

    # ...and the converse. A host that stops claiming any off-site job loses the unit that
    # writes the status file, but NOT the file: node-exporter exports every .prom it finds,
    # forever and with no notion of staleness, so the last value written would be published
    # for the life of the machine. That is how porcupineFish kept reporting a `daily` job
    # after ADR-0036 concluded it has nothing to back up — the same stale-metric trap the
    # phase-0 filenames left, arrived at from the other direction. Removing a producer has to
    # remove its output too.
    (lib.mkIf (cfg.reportJobs == [ ]) {
      systemd.tmpfiles.rules = [ "r ${cfg.metricsDir}/backup-restic-status.prom" ];
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
      # One-time cleanup of the PRE-DESTINATION metric filenames. node-exporter exports every
      # .prom file it finds, forever and with no notion of staleness, so files left behind by
      # the old naming would go on publishing their old label sets: a phantom
      # `{restic_job="daily"}` row with no destination next to the real one, and a
      # `check_success` frozen at whatever it last was — the precise failure these metrics
      # exist to rule out. Activation runs `systemd-tmpfiles --remove`, so a deploy clears
      # them. Safe to delete this block once every host has activated once (after
      # 2026-10-05).
      systemd.tmpfiles.rules = map (f: "r ${cfg.metricsDir}/backup-restic-${f}.prom") (
        lib.concatMap (job: [
          "${job}-lastsuccess"
          "lastprune-${job}"
          "lastcheck-${job}"
          "checksuccess-${job}"
        ]) cfg.reportJobs
      );

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

    # THE CROSS PRODUCT. One restic job per (job × destination), each with its own
    # last-success stamp, retention unit, and — on the elected host — the repository's prune
    # and check.
    {
      services.restic.backups = lib.listToAttrs (map (p: lib.nameValuePair p.name (resticJob p)) pairs);

      systemd.services = lib.mkMerge [
        backupStampServices
        forgetServices
        pruneServices
        checkServices
      ];
      systemd.timers = lib.mkMerge [
        forgetTimers
        pruneTimers
        checkTimers
      ];

      assertions =
        lib.mapAttrsToList (destName: dest: {
          assertion =
            ((dest.repository == null) != (dest.repositoryFile == null)) || (dest.environmentFile != null);
          message = "custom.profiles.backup.destinations.${destName}: set exactly one of repository or repositoryFile (or supply RESTIC_REPOSITORY via environmentFile).";
        }) usedDestinations
        ++ lib.mapAttrsToList (jobName: job: {
          # An enabled job with no paths is the quiet failure hosts/rk1/backup.nix warns
          # about: restic exits 0 having backed up nothing, and the board goes green over an
          # empty snapshot. `settings` can supply `command`/`dynamicFilesFrom` instead.
          assertion = job.paths != [ ] || job.settings ? command || job.settings ? dynamicFilesFrom;
          message = "custom.profiles.backup.jobs.${jobName} is enabled but has no paths — restic would succeed having backed up nothing. Give it paths, or disable the job.";
        }) activeJobs
        ++ lib.mapAttrsToList (
          jobName: job:
          let
            bulk = lib.filter (p: lib.elem (lib.removeSuffix "/" p) bulkRoots) job.paths;
          in
          {
            # ADR-0036: enumerate what is irreplaceable; do not snapshot a machine. Checked
            # for every DECLARED job, not just enabled ones, so the enumeration is written
            # under the rule rather than audited after it ships.
            assertion = bulk == [ ];
            message = "custom.profiles.backup.jobs.${jobName} backs up ${lib.concatStringsSep ", " bulk}, which is a whole-machine root rather than a chosen path (ADR-0036). A bulk backup ships logs, caches and re-downloadable media off-site, inflates every snapshot, and hides the question of what is actually irreplaceable — on this fleet it is also the difference between a 3 GiB snapshot and a 143 GiB one. Name the subtrees that cannot be rebuilt, and record what you left out in `notBackedUp`.";
          }
        ) cfg.jobs
        ++ lib.concatLists (lib.mapAttrsToList persistenceAssertions cfg.jobs)
        ++ lib.mapAttrsToList (
          jobName: _job:
          let
            calendars = map (
              p: (p.job.timerConfig // (p.dest.settings.timerConfig or { })).OnCalendar or null
            ) (lib.filter (p: p.jobName == jobName) pairs);
          in
          {
            # ADR-0035: with more than one destination, staggering is MANDATORY rather than
            # hygiene. Two destinations firing the same job at the same minute read the same
            # tree twice and saturate the same uplink twice, and each one's maintenance
            # window then lands on the other's backup. Offset one with
            # `destinations.<name>.settings.timerConfig`.
            assertion = calendars == lib.unique calendars;
            message = "custom.profiles.backup: job ${jobName} fires at the same time on more than one destination (${lib.concatStringsSep ", " (map toString calendars)}). Offset one with destinations.<name>.settings.timerConfig.";
          }
        ) activeJobs;
    }
  ];
}
