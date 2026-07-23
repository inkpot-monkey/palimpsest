# Beets ingest pipeline — the auto-filing half of the friends' music platform (ADR-0027,
# issue #43). A host-agnostic profile, enabled with `custom.profiles.beets.enable = true`
# (rk1b, the media node, alongside custom.profiles.navidrome).
#
# The shape: a systemd .path unit watches the drop zone (/var/cache/music-inbox); when a
# file lands it fires a throttled `beet import` oneshot. Beets fingerprints (Chromaprint/
# AcoustID), tags from MusicBrainz, fetches cover art, de-dupes, and MOVES confident matches
# into /var/cache/music — the Navidrome library — under an Artist/Album tree. Navidrome's
# inotify watcher (navidrome.nix, Scanner.WatcherEnabled) then auto-scans them in, so tracks
# appear for every friend within seconds with no manual scan. Anything beets can't confidently
# match (untagged-and-unfingerprintable, or a duplicate of an existing track) is left in the
# inbox by quiet-mode beets and swept into /var/cache/music-review for a human to sort later —
# it is never mis-filed into the shared library.
#
# Everything lives on the durable NVMe /var/cache subtree (hosts/rk1/nvme.nix), same as the
# Navidrome library + DB: the inbox, the review quarantine, and beets' own DB/config/logs.
#
# The importer runs as the `navidrome` user (created by services.navidrome) so files land owned
# by the user Navidrome reads as. The library itself is owned by git-annex and shared via the
# `music` group (navidrome.nix) so it can replicate to kelpy, so the importer also runs with
# Group=music and UMask=0002 — see the serviceConfig comment; without that, git-annex cannot
# adopt what beets files.
#
# Metadata matching is MusicBrainz-only (name + track-length). We deliberately do NOT run the
# `chroma` acoustic-fingerprint plugin: on the well-named "Artist - Album / NN - Title" folders
# Soulseek delivers, MusicBrainz already matches at ~distance 0.00, and chroma actively HURT —
# for a classic album pressed in many editions its per-track AcoustID recordings didn't line up
# with the chosen release and it piled on ~0.11 of penalty, pushing a genuinely-correct album
# past the auto-file threshold into review (Cocteau Twins — Treasure, verified live: 0.00 without
# chroma, 0.11 with). The narrow case chroma would still win — a file with NO usable tags AND a
# useless filename — safely lands in the review quarantine anyway.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.custom.profiles.beets;

  # The three ingest directories + beets' own state dir, all on the NVMe /var/cache subtree.
  # `library` is read straight from Navidrome's own MusicFolder (single source of truth — beets
  # files confident matches here and Navidrome's watcher scans them in). The assertion below
  # guarantees Navidrome is enabled, so this is its configured value, not the module default.
  library = config.services.navidrome.settings.MusicFolder;
  inbox = "/var/cache/music-inbox";
  review = "/var/cache/music-review";
  stateDir = "/var/cache/beets";

  # The beets config carries the AcoustID API key, so it is rendered from a sops template (the
  # key is interpolated in at activation, never written to the world-readable Nix store) owned
  # by the navidrome user the importer runs as.
  #   move: yes         — relocate matched files out of the inbox into the library.
  #   quiet_fallback    — in quiet mode (the automated import passes `-q`), import strong matches
  #                       and LEAVE weak ones in the inbox for the sweep-to-quarantine below.
  #   duplicate_action  — a track already in beets' library DB is skipped (→ quarantine), not
  #                       doubled. (Dedup is DB-scoped; see the runbook on seeding the DB from an
  #                       rsync-seeded library so pre-existing tracks are known.)
  #   fetchart.auto     — pull cover art for matched albums.
  # NB: `quiet` is deliberately NOT set here — the automated importer passes `-q` on the CLI, so
  # the config stays interactive and a manual `beet import` (quarantine sorting) actually prompts.
  #
  # `musicbrainz` MUST be in the plugins list: in beets 2.x MusicBrainz is a metadata-source
  # PLUGIN, not core. beets' built-in default config enables it implicitly, but the moment we set
  # an explicit `plugins:` line we override that default — omitting it here means beets finds ZERO
  # match candidates and quarantines every single import. (Verified on rk1b: without it, 0
  # candidates; with it, the tagged test track matched at distance 0.07.)
  beetsConfig = ''
    directory: ${library}
    library: ${stateDir}/library.db

    plugins: musicbrainz fetchart

    import:
      move: yes
      write: yes
      quiet_fallback: skip
      duplicate_action: skip
      log: ${stateDir}/import.log

    # Auto-file clearly-correct albums even in quiet mode. beets' default strong-match threshold
    # (0.04) is tighter than real-world rips clear: a correct album still lands around distance 0.07
    # from tag drift (a 2024 digital reissue vs an original CD rip, an embedded release ID pointing
    # at a sibling edition), which the default downgrades to a *medium* rec — so quiet mode skips it
    # to review and nothing reaches Navidrome unattended. 0.10 promotes those unambiguously-right
    # matches to strong so they auto-file, while still comfortably clearing the ~0.00 MusicBrainz
    # matches the common well-named rip produces. The safety net stays: beets' max_rec caps a match
    # with missing/extra tracks at medium regardless of this, so a genuinely wrong or half-arrived
    # album still falls through to the review sweep rather than mis-filing. (Verified live on rk1b:
    # Daft Punk — Discovery matched at 0.067, and a fully-untagged Cocteau Twins — Treasure at 0.00.)
    match:
      strong_rec_thresh: 0.10

    paths:
      default: $albumartist/$album%aunique{}/$track $title
      singleton: $artist/Non-Album/$title
      comp: Compilations/$album%aunique{}/$track $title

    fetchart:
      auto: yes
      maxwidth: 1200
  '';

  # The importer: import each SETTLED album from the inbox into the library, prune the album dirs
  # beets empties by moving matched tracks out, then sweep whatever it declined into the review
  # quarantine. Draining the inbox to empty is what re-arms the .path unit cleanly — a
  # DirectoryNotEmpty watch would retrigger forever if we left the rejects sitting in the inbox.
  #
  # Two hazards, both learned from live bring-up:
  #   * PARTIAL ALBUMS. music-sync rsyncs each track into the inbox as slskd finishes it (writing a
  #     hidden .name.XXXXXX temp, then renaming), so mid-transfer the inbox holds half-arrived
  #     albums. Tagging one makes beets reject it on track count and quarantine a fragment. So we
  #     only touch an album dir that has SETTLED — no in-flight rsync temp and nothing modified for
  #     QUIESCE_SECS — and leave the rest for the next trigger or the backstop timer. (A slow,
  #     queued download whose files gap by more than the window can still be seen partial; beets'
  #     max_rec caps a wrong-track-count match at medium, so it lands in review, not mis-filed.)
  #   * QUARANTINE COLLISIONS. If beets declines an album whose name is already in review (a prior
  #     fragment, or a re-download), a plain `mv` into review fails "Directory not empty", the
  #     service exits non-zero, the inbox never drains, and the .path unit re-fires forever — a
  #     real infinite loop seen in bring-up. So the sweep suffixes on any clash and ALWAYS drains.
  importer = pkgs.writeShellApplication {
    name = "beets-import";
    runtimeInputs = [
      pkgs.beets
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      QUIESCE_SECS=120

      settled() {
        # An in-flight rsync temp (.name.XXXX) means the album is still transferring.
        [ -z "$(find "$1" -name '.*' -type f -print -quit)" ] || return 1
        # Anything (the album dir entry itself, or its content) touched within the window means it
        # is still arriving. rsync preserves source mtimes on files, but --omit-dir-times leaves the
        # album dir's own mtime tracking real add/rename activity, so the dir entry is the signal.
        local threshold
        threshold=$(( $(date +%s) - QUIESCE_SECS ))
        [ -z "$(find "$1" -newermt "@$threshold" -print -quit)" ] || return 1
        return 0
      }

      # -q runs unattended (no prompts); beet exits non-zero when it skips in quiet mode, which is
      # expected, so `|| true` keeps `set -e` from aborting before we quarantine.
      find "${inbox}" -mindepth 1 -maxdepth 1 -print0 | while IFS= read -r -d "" item; do
        if ! settled "$item"; then
          echo "deferring still-arriving item: $item"
          continue
        fi

        beet -c "$BEETS_CONFIG" import -q "$item" || true

        # Drop the album dir if beets emptied it by moving matched tracks into the library.
        if [ -e "$item" ]; then
          find "$item" -depth -type d -empty -delete 2>/dev/null || true
        fi

        # Anything still here was unmatched, a duplicate, or below the confidence threshold: sweep
        # it to the review quarantine, collision-safe, which also drains the inbox so the .path
        # unit settles instead of re-firing.
        if [ -e "$item" ]; then
          mkdir -p "${review}"
          dest="${review}/$(basename "$item")"
          if [ -e "$dest" ]; then
            dest="$dest.$(date +%Y%m%dT%H%M%S)"
          fi
          mv "$item" "$dest"
        fi
      done
    '';
  };
in
{
  options.custom.profiles.beets = {
    enable = lib.mkEnableOption "Beets ingest pipeline for the Navidrome library";
  };

  config = lib.mkIf cfg.enable {
    # Beets files into Navidrome's library and reads its MusicFolder for the destination, so it
    # is meaningless without Navidrome on the same host — assert rather than silently file into
    # the module-default folder.
    assertions = [
      {
        assertion = config.services.navidrome.enable;
        message = "custom.profiles.beets requires custom.profiles.navidrome — it files into Navidrome's library (services.navidrome.settings.MusicFolder).";
      }
    ];

    sops.templates."beets-config" = {
      content = beetsConfig;
      owner = "navidrome";
    };

    # The inbox, the review quarantine, and beets' DB/config/log dir. navidrome-owned so the
    # importer (which runs as navidrome, to write the 0700 library) owns everything it touches.
    # The library dir itself is created + owned by services.navidrome; we don't redeclare it.
    #
    # The inbox is setgid `music` (2770-style, group-writable) rather than plain navidrome:
    # music-sync on kelpy rsyncs completed downloads into it as the `git-annex` SSH identity
    # (modules/nixos/services/music-sync), and git-annex is in the `music` group on rk1b
    # (hosts/rk1/git-annex.nix). So the inbox has to be group-writable by `music` for the
    # incoming files to land, while navidrome (its owner, also in `music`) still drains it.
    # setgid makes each incoming album dir inherit `music` too, so beets can read+move all of
    # it. The review + state dirs stay navidrome-private — nothing external writes there.
    systemd.tmpfiles.rules = [
      "d ${inbox} 2775 navidrome music -"
      "d ${review} 0755 navidrome navidrome -"
      "d ${stateDir} 0755 navidrome navidrome -"
    ];

    # rsync must be on the system PATH for the INCOMING side of music-sync: when kelpy runs
    # `rsync -e ssh ... git-annex@rk1b:...`, sshd launches `rsync --server` for the git-annex
    # user, resolved from the login PATH (not any unit's PATH). Without this the transfer
    # fails with "rsync: command not found" and downloads never reach the inbox.
    environment.systemPackages = [ pkgs.rsync ];

    # A new file in the inbox fires the importer. DirectoryNotEmpty (not PathExists on a glob)
    # keeps firing until the inbox is fully drained, so a burst of drops all get processed.
    systemd.paths.beets-import = {
      description = "Watch the music inbox and trigger a beets import";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ "/var/cache" ];
      pathConfig.DirectoryNotEmpty = inbox;
    };

    # Backstop: the .path unit fires on the LAST file's arrival, but the importer's quiescence gate
    # defers an album for QUIESCE_SECS after that — by which point no further inotify event will
    # come to re-trigger it. This timer re-runs the importer so a fully-arrived, now-settled album
    # is never stranded waiting for a trigger. Cheap when there's nothing to do (a couple of finds).
    systemd.timers.beets-import = {
      description = "Backstop trigger for the beets importer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/5";
        Persistent = true;
      };
    };

    systemd.services.beets-import = {
      description = "Import dropped files into the Navidrome library via beets";
      # Fingerprinting + MusicBrainz + cover-art all need the network.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # While an album transfers, music-sync's per-file rsync modifies the inbox repeatedly, so the
      # .path unit fires the importer many times in quick succession (each run cheaply defers the
      # still-arriving album). The default rate limit (5 starts / 10s) trips on that and marks the
      # service failed, which stops the .path unit watching. Raise it generously — the importer is
      # idempotent and mostly a no-op during transfer — while still capping a genuine crash-loop.
      startLimitIntervalSec = 60;
      startLimitBurst = 100;
      # Don't strand beets' DB/library on the tmpfs root if the NVMe isn't mounted.
      unitConfig.RequiresMountsFor = [ "/var/cache" ];
      environment = {
        BEETS_CONFIG = config.sops.templates."beets-config".path;
        # beets defaults its state/config under $HOME; pin it at the on-NVMe state dir so it
        # never tries to write into a nonexistent navidrome home.
        HOME = stateDir;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "navidrome";
        # Group + UMask are what let git-annex adopt what beets files. The library is
        # owned by git-annex and shared via the `music` group (navidrome.nix); the
        # importer must therefore create Artist/Album dirs that the git-annex user can
        # write into, because `git annex add` MOVES a file into .git/annex/objects and a
        # rename needs write on the containing directory, not on the file. With the
        # default 022 umask those dirs land 0755 and the move fails — the tracks would
        # sit in the library un-annexed and never replicate. 0002 makes them 0775/0664.
        Group = "music";
        UMask = "0002";
        # Courtesy to the co-located monitoring server: fingerprinting/transcoding is CPU- and
        # IO-heavy, so run it at the lowest CPU priority and idle IO class (the nice/ionice throttle).
        Nice = 19;
        IOSchedulingClass = "idle";
        ExecStart = lib.getExe importer;
      };
    };
  };
}
