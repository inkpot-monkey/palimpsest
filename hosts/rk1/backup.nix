# rk1b's off-site restic job — the first one that actually runs anywhere on the fleet
# (palimpsest#150). Scoped to the Immich photo library: that is now the only tree here whose
# contents are neither re-acquirable (unlike `music`) nor replicated to a second host (unlike
# `library`, which has the kelpy annex replica).
#
# ⚠ kelpy's pattern DOES NOT TRANSFER. kelpy backs up `paths = [ "/persistent" ]` and that
# works there only because impermanence binds its state into /persistent. rk1b's root is a 2G
# tmpfs and its data lives on the NVMe at /var/cache, which is OUTSIDE /persistent — so
# copying kelpy's job here would instantiate a restic unit that reports success every night
# having backed up none of the photos. The paths below name the Immich tree explicitly, and
# are derived from the profile rather than hardcoded so they cannot drift from it.
#
# Equally: rk1b had no `daily` job at all before this file, only `reportJobs = [ "telemetry" ]`.
# `custom.profiles.backup` supplies the repository and password but NOT `paths` — each host
# brings its own — so this is a job being created, not a path being edited.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  immich = config.custom.profiles.immich;

  # Immich's own nightly logical dump, written inside mediaLocation. See the paths note below
  # for why this is the database backup rather than a pg_dump of our own.
  dumpDir = "${immich.mediaLocation}/backups";

  # One missed Immich dump is tolerated, two is not — and since the job moved to 03:00/15:00
  # (an hour after Immich's 02:00 dump) that is now exactly what 48h means: the 03:00 run sees
  # a ~1h-old dump in steady state, ~25h if last night's dump was missed, and ~49h if two
  # were. So the guard fires on the second consecutive miss and not before.
  maxDumpAgeSeconds = 48 * 60 * 60;

  # Fail the job loudly rather than ship a snapshot whose database half is stale. The whole
  # argument for this guard, and why it is a hard failure rather than a warning, is in the
  # header of the file it comes from — read that before changing the threshold. It lives there
  # rather than inline so parts/checks/immich-db-dump-freshness can exercise the real script.
  requireFreshDump = import ../../modules/nixos/profiles/immich-db-dump-freshness.nix {
    inherit pkgs dumpDir;
    maxAgeSeconds = maxDumpAgeSeconds;
  };
in
{
  # Guard the pairing, as rk1/git-annex.nix guards Navidrome: every path below is derived from
  # the Immich profile, so without it this job would back up a directory that does not exist
  # and restic would succeed on an empty file set.
  assertions = [
    {
      assertion = immich.enable;
      message = "hosts/rk1/backup.nix backs up the Immich library (custom.profiles.immich.mediaLocation), but that profile is not enabled — enable it, or drop this import.";
    }
    {
      assertion = immich.enable -> lib.hasPrefix "/var/cache/" immich.mediaLocation;
      message = "hosts/rk1/backup.nix assumes Immich's media sits on the NVMe /var/cache subtree; mediaLocation is now ${immich.mediaLocation}. If it has moved back under the tmpfs root, the photos are not durable at all and backing them up is the wrong fix.";
    }
  ];

  # ON — the fleet's first live off-site job. #150 recorded the fleet-wide default as
  # DEFERRED, not blocked (rsync.net resolves and TCP 22 connects), and the photo library is
  # what cashes that deferral in: 782 assets imported from Google Photos as of 2026-09-28,
  # held on exactly one host, with no replica anywhere.
  #
  # VERIFIED LIVE 2026-10-05: 8 snapshots in the rsync.net repository and the fleet's first
  # ever `restic check` reporting "no errors were found" over 10% of its pack data. The two
  # unknowns #150 recorded are both settled — the account has quota, and the 212-day stale
  # exclusive lock left by the decommissioned stargazer config was cleared by hand (the
  # module's own `unlock` runs AFTER the backup, so it can never rescue a first run).
  #
  # Units are named per destination now: restic-backups-daily-rsyncnet.service, and
  #   journalctl -u restic-backups-daily-rsyncnet -f
  custom.profiles.backup.enable = true;

  # Telemetry stays off — separate decision, separate RPO, and it is bulk metrics rather than
  # irreplaceable data. Listing BOTH jobs keeps the Backups board honest: `daily` draws as a
  # live edge and `telemetry` as a known-disabled one, instead of telemetry vanishing.
  custom.profiles.backup.monitoringTelemetry.enable = false;

  # rk1b is the ELECTED MAINTAINER of the rsync.net repository: `prune` and `check` are
  # repository-wide operations, not per-host ones (the whole fleet writes into one repository
  # and snapshots are told apart by restic's own hostname field), so exactly one host must run
  # them. rk1b is the right one — always on, and the largest contributor to the repository.
  #
  # ⚠ When phase 3 enables backups on kelpy, porcupineFish and sawtoothShark, leave
  # `maintenance` at its default (false) there. Their retention still runs locally; only the
  # repack and the integrity check belong to one host.
  custom.profiles.backup.destinations.rsyncnet.maintenance = true;
  custom.profiles.backup.reportJobs = [
    "daily"
    "telemetry"
  ];

  # WHAT to back up. The profile owns WHERE it goes (`destinations`), so this host declares
  # its data once and any destination added later picks it up with no edit here.
  custom.profiles.backup.jobs.daily = {
    # Named subtrees, NOT mediaLocation wholesale. Immich mixes irreplaceable originals with
    # large derived caches in one directory, and the split matters in both directions:
    #
    #   upload/   the originals. The only copy of the bytes. ~1.0G today.
    #   library/  external libraries — empty today, but it holds ORIGINALS when used, so it is
    #             listed now rather than discovered missing after someone mounts a folder.
    #   profile/  user avatars. Tiny, not regenerable.
    #   backups/  Immich's own nightly pg dump — where albums, people, faces, share links and
    #             every asset's EXIF actually live. ~102M. The pixels are worth little without
    #             it, which is why its freshness is enforced above.
    #
    # Deliberately NOT backed up — all of it is derived from upload/ and rebuilt by Immich's
    # own jobs, so it is ~1.06G of pure cost today and growing:
    #   thumbs/ (269M), clip/ (583M), facial-recognition/ (183M), ocr/ (21M),
    #   encoded-video/, huggingface/ (model cache, re-downloaded on demand)
    # These churn as the ML worker re-runs, so including them would also defeat restic's
    # dedup and inflate every snapshot for no restore value.
    #
    # /var/cache/postgresql — the LIVE cluster — is also deliberately absent. Copying a
    # running postgres data directory produces a snapshot that may not replay, and Immich
    # already writes a consistent logical dump into backups/ on a schedule. A restore wants
    # that file, not a torn cluster; two half-trustworthy copies of the database would be
    # worse than one good one.
    paths = [
      "${immich.mediaLocation}/upload"
      "${immich.mediaLocation}/library"
      "${immich.mediaLocation}/profile"
      dumpDir
    ];

    # Fail the job rather than ship a snapshot whose database half is stale. See the comment
    # on requireFreshDump — this is what stops a silently-broken Immich dump from presenting
    # as a healthy backup. Applies on every destination: a second copy of a stale pair is no
    # better than the first.
    settings.backupPrepareCommand = "exec ${requireFreshDump}";
  };
}
