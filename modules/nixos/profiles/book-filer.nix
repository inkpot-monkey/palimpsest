# Book filer — the auto-filing half of the document library (ADR-0031, palimpsest#144).
# A host-agnostic profile, enabled with `custom.profiles.book-filer.enable = true` (rk1b, where
# the library tree lives, alongside custom.profiles.stump).
#
# The music analogue is beets (profiles/beets.nix, ADR-0027/#43): a drop zone, a periodic
# importer, and a library it files into. Books need far less machinery — an EPUB's OPF is
# usually already correct, where a ripped track's tags are not — so there is NO network lookup,
# no fingerprinting and no confidence threshold here. `dc:title` / `dc:creator` are read out of
# the file and the book is renamed to `<Title> - <Author>.epub`. The git-annex assistant already
# adds, commits and syncs anything appearing in the tree, and Stump's watcher scans it in, so
# this profile's entire job is the one hop in between.
#
# THE SUBJECT IS NEVER GUESSED. EPUBs rarely carry a usable `dc:subject`, and the Stump
# libraries are SERIES_BASED — one folder IS one series — so the folder is a real curation
# decision. The human expresses it by WHERE THEY DROP THE FILE, and everything else is automated:
#
#     books-inbox/Food/Invitation to a Banquet … Anna's Archive.epub
#       → library/books/Food/Invitation to a Banquet - Fuchsia Dunlop.epub
#
# ── Why a timer and NOT a `.path` unit (the trap beets fell into) ─────────────────────────────
# beets watches its inbox with `systemd.paths` + `DirectoryNotEmpty`. Copying that here would be
# a permanent version of a bug beets only hit transiently. `DirectoryNotEmpty` is LEVEL-triggered
# and non-recursive, and the subject folders here are PERMANENT, curated directories that outlive
# every book filed out of them — so the inbox is non-empty forever, the unit re-fires the instant
# each run exits, and the result is the ~91-starts-per-second spin documented in beets.nix, with
# no quiet state to recover into. Compounding it, this filer deliberately LEAVES failures in the
# inbox (see below), which would pin the trigger high on every bad drop. A 2-minute timer has
# none of that: a run with nothing to do is one directory walk, and nobody is waiting on a book
# they just dropped with a stopwatch.
#
# ── Two filesystem facts the design is built around ───────────────────────────────────────────
# 1. `rename(2)` PRESERVES OWNERSHIP, so the filer cannot simply move the drop. The dropped file
#    belongs to the human who dropped it; the filed book must belong to `git-annex`, because only
#    the git-annex user holds the fleet annex SSH key and the replicating node must own what it
#    replicates (ADR-0028's model, reused by ADR-0031). Running as git-annex, the filer has no
#    CAP_CHOWN to correct that after the fact. So it COPIES into a git-annex-owned staging
#    directory — where the copy is git-annex-owned by construction — and renames from there into
#    the tree. Staging shares the /var/cache NVMe filesystem with the library, so that rename is
#    atomic and the assistant never sees a partial file.
# 2. UNLINKING NEEDS WRITE ON THE CONTAINING DIRECTORY, not on the file. A subject folder the
#    human mkdirs inside the inbox inherits group `library` from the setgid bit but takes its
#    MODE from their umask — 2755, not group-writable — so git-annex could read the drop and
#    never remove it, re-filing the same book on every pass. The inbox therefore carries a
#    DEFAULT POSIX ACL granting `library` rwx, so every folder created inside it is
#    group-writable however the client's umask is set. Note the direction: this admits git-annex
#    to the INBOX; it deliberately does NOT admit the human to the corpus, which stays 2770
#    git-annex:library with the human outside the `library` group.
#
# ── Failure is always "a human owes this file a decision" ─────────────────────────────────────
# Missing metadata, a name collision, a non-EPUB, a drop with no subject folder: every one leaves
# the file exactly where it was put, logs why, and raises a counter. Nothing is ever overwritten,
# suffixed, deleted or guessed — this is the one thing standing between a downloads folder and an
# irreplaceable personal corpus, and "the filer decided my file was a duplicate" is the worst
# failure it could have. The counters go to the node-exporter textfile collector so a stuck file
# is discoverable without reading the journal, alongside a last-run timestamp — without which a
# DEAD TIMER and a CLEAN INBOX are the same reading (zero stuck files).
#
# Operating this — how to drop, what the gauge means, how to clear a stuck file — is
# docs/runbooks/book-filing.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.custom.profiles.book-filer;

  # Plain interpreter + script path, the same shape profiles/supernote.nix uses for its mirror.
  # `writers.writePython3Bin` would lint the script with flake8's 79-column default, which this
  # repo's own formatter (ruff, via treefmt) does not impose — so the writer would reject a file
  # `nix fmt` considers correct.
  filer = pkgs.writeShellScript "book-filer" ''
    exec ${pkgs.python3}/bin/python ${./book-filer.py}
  '';

  # The library tree's own convention (hosts/rk1/library.nix): setgid so group `library` flows
  # down to everything created inside, and no world access — these are personal documents.
  treeDirMode = "2770";
  # The inbox is the ONE directory the human owns and writes; group-writable so the filer (as
  # git-annex, via `library`) can drain it, setgid so subject folders inherit the group.
  inboxMode = "2775";

  directories = pkgs.writeShellScript "book-filer-directories" ''
    set -eu
    install -d -o ${cfg.dropUser} -g ${cfg.group} -m ${inboxMode} ${cfg.inboxPath}
    install -d -o ${cfg.owner} -g ${cfg.group} -m ${treeDirMode} ${cfg.stagingPath}
    install -d -o ${cfg.owner} -g ${cfg.group} -m ${treeDirMode} ${cfg.destPath}

    # See the header, fact 2. The DEFAULT entry (-d) is what every subject folder created inside
    # inherits; the access entry covers the inbox root itself. Without this the filer can read a
    # drop and never unlink it, and the inbox silently never drains.
    ${lib.getExe' pkgs.acl "setfacl"} -m g:${cfg.group}:rwx ${cfg.inboxPath}
    ${lib.getExe' pkgs.acl "setfacl"} -d -m g:${cfg.group}:rwx ${cfg.inboxPath}
  '';
in
{
  options.custom.profiles.book-filer = {
    enable = lib.mkEnableOption "Book filer — file dropped EPUBs into the library from embedded metadata (palimpsest#144)";

    inboxPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/books-inbox";
      description = ''
        Drop zone. A book is filed by placing it in `<inboxPath>/<Subject>/`, where the subject
        folder names the series it belongs to — that folder is the human's only input.

        Deliberately OUTSIDE the git-annex library tree, though on the same filesystem. Inside
        it, the assistant would annex, commit and replicate every raw download the instant it
        landed — junk filenames into git history and onto kelpy, and half-written files adopted
        mid-transfer — and the module offers no gitignore mechanism to prevent it.
      '';
    };

    stagingPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/books-staging";
      description = ''
        Scratch space for the copy-then-rename, owned by `owner` so the copy is correctly owned
        by construction (see the header, fact 1). MUST be on the same filesystem as `destPath`,
        or the rename into the tree stops being atomic and the git-annex assistant can catch a
        partial file. Also outside the tree, so the assistant never sees the scratch copy.
      '';
    };

    libraryPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/library";
      description = "Root of the git-annex document-library tree (hosts/rk1/library.nix).";
    };

    destPath = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.libraryPath}/books";
      defaultText = lib.literalExpression ''"''${config.custom.profiles.book-filer.libraryPath}/books"'';
      description = ''
        The `books/` root Stump indexes (profiles/stump.nix). Filed books land in
        `<destPath>/<Subject>/<Title> - <Author>.epub`, mirroring the inbox's own layout.
      '';
    };

    owner = lib.mkOption {
      type = lib.types.str;
      default = "git-annex";
      description = ''
        User the filer runs as, and therefore the owner of everything it files. git-annex owns
        the tree because only it holds the fleet annex SSH key (ADR-0028), so running AS that
        user makes correct ownership a consequence of who ran rather than a chown that can drift
        — and the filer needs no CAP_CHOWN.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "library";
      description = ''
        Group owning the library tree (hosts/rk1/library.nix, GID pinned at 977). Filed content
        carries it so Stump — which reads the corpus only as a member of this group — can see it.
      '';
    };

    dropUser = lib.mkOption {
      type = lib.types.str;
      default = "inkpotmonkey";
      description = ''
        Account that owns the inbox and drops books into it over SSH. Deliberately NOT a member
        of `group`: it needs to write its own drop zone, not the document corpus, and keeping it
        out means an accidental `rm` in the tree is not one command away from replicating to
        kelpy. The default ACL on the inbox is what lets the filer reach in the other direction.
      '';
    };

    quiesceSeconds = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Ignore files modified more recently than this. `scp` writes in place with no
        temp-and-rename, so a pass can meet a half-arrived book. Its OPF would be unreadable and
        it would report as missing metadata, bumping the stuck gauge — then file cleanly two
        minutes later. That teaches an operator to ignore the gauge, so "still arriving" and
        "genuinely broken" are kept as distinct states. Unreadable-EPUB detection remains as the
        backstop for a transfer that stalls for longer than this window.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/2";
      description = ''
        `OnCalendar` for the filing pass. A timer rather than a `systemd.path` watch on purpose —
        see the header: the permanent subject folders make `DirectoryNotEmpty` permanently true.
      '';
    };

    writeMetrics = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Publish `books_inbox_stuck_files{reason=…}` and `books_inbox_last_run_timestamp_seconds`
        to the node-exporter textfile directory. Requires the monitoring-exporters profile, which
        owns `metricsDir` and the `node-exporter` group the unit joins to write there.
      '';
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "node-exporter textfile collector directory (see monitoring-exporters).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The filer writes into a tree it does not create; without the library repository it
        # would file into a bare directory that never replicates and that Stump never indexes.
        assertion = config.services.git-annex.repositories ? library;
        message = "custom.profiles.book-filer files into the git-annex `library` tree — import hosts/rk1/library.nix on this host, or point `destPath` somewhere that exists.";
      }
      {
        # `SupplementaryGroups = [ "node-exporter" ]` below refers to a group that only the
        # exporters profile creates; without it the unit fails to start every two minutes.
        assertion = cfg.writeMetrics -> config.services.prometheus.exporters.node.enable;
        message = "custom.profiles.book-filer.writeMetrics needs the monitoring-exporters profile (it owns metricsDir and the node-exporter group) — enable it, or set writeMetrics = false.";
      }
    ];

    # A oneshot rather than systemd.tmpfiles rules, for the reason profiles/stump.nix:365
    # documents: tmpfiles can win the race against the NVMe mount and create these on the tmpfs
    # root, where they then SHADOW the real directories once /var/cache appears. `install -d` is
    # idempotent, and `RequiresMountsFor` makes the ordering explicit rather than lucky.
    systemd.services.book-filer-directories = {
      description = "Ensure the book inbox, its ACL, and the staging + books directories exist";
      wantedBy = [ "multi-user.target" ];
      before = [ "book-filer.service" ];
      unitConfig.RequiresMountsFor = [
        cfg.inboxPath
        cfg.libraryPath
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = directories;
      };
    };

    systemd.timers.book-filer = {
      description = "Periodic pass over the book inbox";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        # Catch up a pass missed while the host was down, so a book dropped just before a reboot
        # is filed at boot rather than waiting for the next tick.
        Persistent = true;
      };
    };

    systemd.services.book-filer = {
      description = "File dropped EPUBs into the document library (palimpsest#144)";
      # Deliberately NO network dependency: unlike beets there is no MusicBrainz lookup, no
      # fingerprinting and no cover fetch. Everything this needs is inside the file.
      requires = [ "book-filer-directories.service" ];
      after = [ "book-filer-directories.service" ];
      unitConfig.RequiresMountsFor = [
        cfg.inboxPath
        cfg.libraryPath
      ];
      environment = {
        BOOKS_INBOX = cfg.inboxPath;
        BOOKS_DEST = cfg.destPath;
        BOOKS_STAGING = cfg.stagingPath;
        BOOKS_QUIESCE_SECS = toString cfg.quiesceSeconds;
        BOOKS_METRICS_DIR = lib.optionalString cfg.writeMetrics (toString cfg.metricsDir);
      };
      serviceConfig = {
        Type = "oneshot";
        User = cfg.owner;
        Group = cfg.group;
        # The textfile directory is 0775 node-exporter:node-exporter (monitoring/exporters.nix),
        # and this runs as git-annex — so publishing metrics needs the group. Scoped to the unit
        # rather than granted to the git-annex user (as monitoring/tlsrpt.nix does for its own
        # static user), because nothing else git-annex does should reach that directory.
        SupplementaryGroups = lib.optionals cfg.writeMetrics [ "node-exporter" ];
        # Everything created lands group-writable and group-confined: 2770 dirs / 664 files, the
        # tree's convention. The script chmods explicitly too — the umask only covers the gap
        # between creat() and that chmod.
        UMask = "0007";
        # Courtesy to the co-located monitoring server: this copies whole books around on a
        # 2-minute timer, and nothing is waiting on it.
        Nice = 19;
        IOSchedulingClass = "idle";
        ExecStart = filer;
      };
    };
  };
}
