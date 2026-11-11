# rk1a's off-site restic job: Home Assistant's state, and the uid map that makes restoring it
# mean anything.
#
# The sibling of ./backup.nix (rk1b's), and deliberately a separate file rather than a shared
# one: the two hosts share a destination and nothing else. rk1b's job is photos and an annex
# library measured in gigabytes on an NVMe outside the impermanence root; this one is 1-2 MB of
# JSON and a small SQLite dump inside it. The arguments differ, so the files differ.
#
# ── WHAT IS IRREPLACEABLE HERE, AND WHAT ONLY LOOKS LIKE IT ──────────────────────────────────
# Almost everything about this host is in the flake. Home Assistant's YAML, the Wyoming models,
# the bulbs' addresses and device types, the voice pipeline, the HTTP settings — all declarative,
# all reproducible from this repository plus the stash (ADR-0037, and the provisioner that pushes
# the parts HA keeps in its own store). That is unusually complete, and it means the thing worth
# backing up is small and specific rather than "the machine":
#
#   /var/lib/hass/.storage   Home Assistant's own store: the config entries, the entity, device
#                            and area registries, the auth store (the owner account and every
#                            issued refresh token, including the phone's), the dashboards. 416K.
#                            ⚠ The provisioner can RECREATE most of this from nix — that is the
#                            whole point of ha-provision.py — but not all of it: entity ids
#                            renamed in the UI, the dashboards, and the long-lived tokens the
#                            Companion app holds are nowhere else. Restoring this directory is
#                            the difference between the house working and re-pairing the phone.
#   the recorder dump        The house's PAST: state history, and the long-term statistics the
#                            energy dashboard and every long-range graph are drawn from. Nothing
#                            regenerates those. Travels as `db_<UTC>.sqlite3`, never as the live
#                            database — see modules/nixos/profiles/ha-db-dump.nix.
#   /var/lib/nixos           24K, and load-bearing for the two above. It is the uid/gid map, and
#                            `hass` has no static uid: rebuild this host without it and the
#                            service user is re-allocated, so every restored file in
#                            /var/lib/hass belongs to the wrong user and Home Assistant
#                            crash-loops on "Permission denied" — the failure
#                            [[kelpy-uid-map-drift]] records, arrived at from the restore side.
#                            rk1b declines this file for a good reason that does not hold here:
#                            its restored trees are git-annex's and Immich's, which it rebuilds
#                            rather than owns. The one tree restored here IS a service user's.
#
# ── WHAT THIS HOST CANNOT DO, STATED SO NOBODY ASSUMES OTHERWISE ─────────────────────────────
# rk1a holds no matrix credential — secrets/.sops.yaml keys profiles/matrix.yaml to admin, kelpy
# and rk1b only — so every alerter here degrades to a journal line (alert-post.nix handles a null
# webhook by design). The signal for a broken backup on this host is therefore the Backups board
# going cold: `backup_restic_last_success_timestamp_seconds` stops advancing, which is exactly
# what the freshness gate below is built to cause rather than mask. Widening matrix.yaml to reach
# this host would hand it every bridge credential on the fleet to gain one alert, which is the
# wrong trade; a push-relay grant (ADR-0020, monitoring.yaml) would be the cheaper way in if the
# alert is ever wanted.
#
# Also worth knowing: this host's root is a 2G tmpfs, so restic's metadata cache under /var/cache
# does not survive a reboot and the first run after one re-downloads it. Measured on rk1b, that
# cache is ~9 MB for the whole shared repository — metadata only, no pack data — so this is a few
# seconds, not a reason to persist another directory (which would also have to be classified
# below for no benefit).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  ha = config.custom.profiles.homeassistant;

  # Home Assistant's state as the BACKUP sees it: the impermanence backing store, not the
  # bind-mounted /var/lib/hass the service sees. Derived from the service's own option so the
  # paths here cannot drift from where it actually writes.
  haStateDir = "/persistent${config.services.home-assistant.configDir}";

  # The live recorder database and the two files SQLite keeps beside it. Excluded, and named once
  # here because three places need the same list: the exclusions, the assertion that they are
  # still in place, and the reader trying to work out what travels.
  liveDb = [
    "${haStateDir}/home-assistant_v2.db"
    "${haStateDir}/home-assistant_v2.db-wal"
    "${haStateDir}/home-assistant_v2.db-shm"
  ];

  # 20h. With dumps at 02:45/14:45 and restic at 03:00/15:00, a healthy run sees a 15-minute-old
  # dump; one missed dump puts the next run at ~12h15m, which must still pass (a single skipped
  # timer is weather, not a fault); a dead timer crosses 24h within a day. So this fires on the
  # SECOND consecutive miss and not before — the same shape as the Immich guard's 48h next door,
  # scaled to a dump that runs twice as often.
  maxDumpAgeSeconds = 20 * 60 * 60;

  # Fail the job loudly rather than ship a snapshot whose history half is missing or stale. The
  # whole argument — including why this gate PASSES when there is no database at all, unlike its
  # paperless sibling, and the kelpy outage that taught it — is in the header of the file it
  # comes from. It lives there rather than inline so parts/checks/ha-dump-freshness can exercise
  # the real script.
  requireFreshDump = import ../../modules/nixos/profiles/ha-dump-freshness.nix {
    inherit pkgs;
    stateDir = haStateDir;
    maxAgeSeconds = maxDumpAgeSeconds;
  };
in
{
  # Guard the pairing, as ./backup.nix does for Immich: every path below is derived from the Home
  # Assistant profile, so without this the job would back up a directory that does not exist and
  # restic would report success over an empty file set.
  assertions = [
    {
      assertion = ha.enable;
      message = "hosts/rk1/ha-backup.nix backs up Home Assistant's state (services.home-assistant.configDir), but custom.profiles.homeassistant is not enabled on this host — enable it, or drop this import.";
    }
    {
      # The three-part pairing, as hosts/kelpy makes for paperless: the dump must be ON, the live
      # database must stay EXCLUDED, and the gate must still be WIRED. Any one of the three
      # missing turns this job into a snapshot that reports success while carrying either no
      # history at all or an unopenable copy of it — and the first two failures are silent.
      assertion =
        ha.enable
        -> (
          ha.backup.dump.enable
          && lib.all (p: lib.elem p config.custom.profiles.backup.jobs.daily.exclude) liveDb
          && lib.hasInfix "ha-dump-freshness" (
            config.custom.profiles.backup.jobs.daily.settings.backupPrepareCommand or ""
          )
        );
      message = "hosts/rk1/ha-backup.nix: Home Assistant is enabled, so its recorder dump must stay on (custom.profiles.homeassistant.backup.dump.enable), the live home-assistant_v2.db triple must stay excluded from the daily job, AND that job's backupPrepareCommand must still invoke the ha-dump-freshness gate. Any one of the three missing is a snapshot that carries this house's configuration with its history either absent or torn — and nothing on the host would be failing to say so.";
    }
  ];

  # ON. The fleet's third live off-site job, after rk1b's (the first, see ./backup.nix) and
  # kelpy's. Enabling it needs rk1a on profiles/restic.yaml in the stash — the repository
  # password, its address, and the SSH key — which is the same grant kelpy, porcupineFish and
  # rk1b already hold. Worth saying plainly: that grant lets this host read and delete the whole
  # shared repository, the mail store and the vault dumps included. It is the fleet's existing
  # model (one repository, snapshots told apart by restic's hostname field) rather than a new
  # exposure, but it is an exposure, and a compromised voice node is not obviously less likely
  # than a compromised anything else. The alternative — a second repository with its own key per
  # host — is a real design, and not this change.
  custom.profiles.backup.enable = true;

  # No telemetry job here, and not merely disabled: that job snapshots VictoriaMetrics through
  # its /snapshot/create API, and the monitoring SERVER runs on rk1b. There is nothing on rk1a
  # for it to snapshot. So, unlike rk1b — which lists both jobs so a switched-off telemetry draws
  # as a known-off edge on the Backups board rather than vanishing — this host claims `daily`
  # only. Claiming a job it could never run would draw a permanently-cold edge and teach the
  # board's reader to ignore cold edges.
  custom.profiles.backup.monitoringTelemetry.enable = false;
  custom.profiles.backup.reportJobs = [ "daily" ];

  # `maintenance` is deliberately NOT set: `prune` and `check` are repository-wide operations on
  # a repository the whole fleet writes into, so exactly one host must run them and that host is
  # rk1b (always on, largest contributor — see ./backup.nix). Retention still runs locally here,
  # scoped to this host's own snapshots of this job.

  # WHAT to back up. The profile owns WHERE it goes, so this host declares its data once.
  custom.profiles.backup.jobs.daily = {
    # Every directory impermanence keeps on this host must be classified below — backed up, or
    # declined with a reason (ADR-0036). This is what makes "we back up Home Assistant" a
    # statement the build can check rather than a hope: the day someone enables a service here
    # that persists state, this FAILS until a human decides whether that state matters.
    classifyPersistence = "/persistent";

    paths = [
      # Home Assistant's whole state directory, minus the exclusions below. The dumps land
      # inside it, beside the database they replace, which is why no extra path is needed.
      #
      # ⚠ `configuration.yaml` in here is a SYMLINK into /etc/home-assistant, written by nix.
      # restic stores the link, not its target, so a restore produces a dangling symlink that
      # the first deploy repairs. That is correct — the YAML belongs to the flake — but it is
      # surprising in a file listing, so: expected.
      haStateDir

      # The uid/gid map, 24K. Not state anyone cares about in itself; it is what makes the
      # directory above restorable to the right owner. See the header.
      "/persistent/var/lib/nixos"
    ];

    exclude = liveDb ++ [
      # ── Home Assistant's duplicate log ─────────────────────────────────────────────────
      # Every line in it is already in the journal, and from there in VictoriaLogs (ADR-0021).
      # The glob catches the active file, its rotation, the `.old` left behind when
      # `logging.fileLog` was turned off, and the `.log.fault` faulthandler dump — which is a
      # crash artifact for a process on THIS host, read here with journalctl beside it, not
      # something a restore wants. Excluded for the reason rk1b gives for /var/log: logs churn
      # nightly, inflating each snapshot and defeating dedup, and no restore anyone wants
      # begins with last week's log.
      "${haStateDir}/home-assistant.log*"

      # ── Derived caches inside the state directory ──────────────────────────────────────
      #   .cache  12M, and the largest thing in here: the downloaded brand/icon set and
      #           scapy's cache. Re-fetched on demand.
      #   tts     synthesised speech, cached per phrase. Piper regenerates it from the text.
      #   deps    where Home Assistant would pip-install at runtime. It cannot on NixOS
      #           (--skip-pip), so this is empty and stays empty; named anyway so a future
      #           non-empty one is a decision rather than a surprise in the snapshot.
      "${haStateDir}/.cache"
      "${haStateDir}/tts"
      "${haStateDir}/deps"
    ];

    # Everything else this host keeps across reboots, and why it does not travel.
    notBackedUp = {
      "/boot" = "regenerated by the bootloader installer on every deploy, from the flake";
      "/etc/nixos" = "the flake is this repository: in git, pushed, and on every other host";
      "/var/log" =
        "382M of journal on a 29G eMMC, churning nightly — it would inflate every snapshot, defeat dedup, and no restore anyone wants begins with last week's journal. The actionable part of it is already shipped live to VictoriaLogs by Vector (ADR-0021), which is a better copy than a nightly one";
      "/var/lib/private" =
        "121M of systemd state directories for DynamicUser services, and all of it re-acquirable: the piper voices and faster-whisper model are downloads pinned by hash in the flake (the profile assembles the model dir from fetchurl), and vector's 12K is a journal cursor whose only function is to avoid re-sending log lines. It also still holds an empty llama-cpp directory from the retired LLM stack — an impermanence orphan, since nothing prunes /persistent when a service is removed";
      "/var/cache/private" =
        "empty, and by construction: a cache directory for DynamicUser services, which is where a service is told to keep what it can rebuild";
      "/var/lib/tailscale" =
        "a node identity, re-authed in one command, and better rotated than restored after an incident";
    };

    # Fail the job rather than ship a snapshot whose history half is missing or stale. See the
    # comment on requireFreshDump — this is what stops a silently-stopped dump from presenting as
    # a healthy backup. Applies on every destination: a second copy of a broken pair is no better
    # than the first.
    settings.backupPrepareCommand = "exec ${requireFreshDump}";
  };
}
