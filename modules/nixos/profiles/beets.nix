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
# adopt what beets files. `fpcalc` (chromaprint) and pyacoustid are on PATH for
# free: nixpkgs' `beets` enables the `chroma` + `fetchart` plugins and wraps the binary with
# their helper bins, so we only select them in the config, not repackage anything.
{
  config,
  lib,
  pkgs,
  self,
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
  #   chroma.auto       — fingerprint every import, so even untagged files get identified.
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

    plugins: musicbrainz chroma fetchart

    import:
      move: yes
      write: yes
      quiet_fallback: skip
      duplicate_action: skip
      log: ${stateDir}/import.log

    paths:
      default: $albumartist/$album%aunique{}/$track $title
      singleton: $artist/Non-Album/$title
      comp: Compilations/$album%aunique{}/$track $title

    chroma:
      auto: yes

    acoustid:
      apikey: ${config.sops.placeholder.acoustid_api_key}

    fetchart:
      auto: yes
      maxwidth: 1200
  '';

  # The importer: import the inbox, prune the empty album dirs beets leaves after moving matched
  # files out, then sweep whatever remains (unmatched / duplicates / low-confidence) into the
  # review quarantine. Draining the inbox to empty is what re-arms the .path unit cleanly — a
  # DirectoryNotEmpty watch would retrigger forever if we left the rejects sitting in the inbox.
  importer = pkgs.writeShellApplication {
    name = "beets-import";
    runtimeInputs = [
      pkgs.beets
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      # -q makes this run unattended (no prompts); beet exits non-zero when it skips items in
      # quiet mode, which is expected, so don't let `set -e` abort before we quarantine. Rejects
      # staying in the inbox is a fail-safe outcome (a human sorts them) — far better than
      # mis-filing into the shared library.
      beet -c "$BEETS_CONFIG" import -q "${inbox}" || true

      # Remove album dirs beets emptied by moving their matched tracks into the library.
      find "${inbox}" -mindepth 1 -type d -empty -delete

      # Anything still here is unmatched, a duplicate, or below the confidence threshold: it must
      # not reach the library. Sweep it to the review quarantine, which also empties the inbox and
      # lets the .path unit settle instead of re-firing.
      if [ -n "$(find "${inbox}" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        mkdir -p "${review}"
        find "${inbox}" -mindepth 1 -maxdepth 1 -exec mv -t "${review}" {} +
      fi
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

    # AcoustID key lives in the navidrome sops bundle (profiles/navidrome.yaml, already keyed
    # admin+rk1b): beets is the Navidrome ingest, on the same host, so it rides the same file
    # rather than forcing a new sops file + per-host re-key. Declared so the placeholder exists
    # for the config template above.
    sops.secrets.acoustid_api_key.sopsFile = self.lib.getSecretFile "navidrome";
    sops.templates."beets-config" = {
      content = beetsConfig;
      owner = "navidrome";
    };

    # The inbox, the review quarantine, and beets' DB/config/log dir. navidrome-owned so the
    # importer (which runs as navidrome, to write the 0700 library) owns everything it touches.
    # The library dir itself is created + owned by services.navidrome; we don't redeclare it.
    systemd.tmpfiles.rules = [
      "d ${inbox} 0755 navidrome navidrome -"
      "d ${review} 0755 navidrome navidrome -"
      "d ${stateDir} 0755 navidrome navidrome -"
    ];

    # A new file in the inbox fires the importer. DirectoryNotEmpty (not PathExists on a glob)
    # keeps firing until the inbox is fully drained, so a burst of drops all get processed.
    systemd.paths.beets-import = {
      description = "Watch the music inbox and trigger a beets import";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ "/var/cache" ];
      pathConfig.DirectoryNotEmpty = inbox;
    };

    systemd.services.beets-import = {
      description = "Import dropped files into the Navidrome library via beets";
      # Fingerprinting + MusicBrainz + cover-art all need the network.
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
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
