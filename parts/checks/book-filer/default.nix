# Acceptance test for the book filer (palimpsest#144, ADR-0031).
#
# Drives the ticket's acceptance criteria against the REAL profile on a REAL 2770
# git-annex:library tree, with the books dropped by a REAL unprivileged human account over the
# same permission boundary production has.
#
# Deliberately FILER-ONLY. It does not stand up git-annex and does not stand up Stump:
#   * that a file appearing in the tree is adopted, committed and replicated is already proven by
#     modules/nixos/services/git-annex/tests/git-annex-library.nix;
#   * that a file under `books/` becomes a catalog entry is proven in parts/checks/stump, which
#     already has a real server and a real corpus standing up — adding a second Stump here would
#     triple the runtime to re-prove someone else's property.
# What is left is the hop in between, which nothing else covers.
#
# ── The four assertions that are DISCRIMINATING, i.e. that fail if the design is wrong ────────
#
# 1. THE DEFAULT ACL, which is the whole reason the inbox drains. A subject folder the human
#    mkdirs takes its mode from THEIR umask — 2755, group-readable but not group-writable — and
#    unlinking a file needs write on its CONTAINING directory. So without the default ACL the
#    filer can read the drop, copy it into the library, and then be unable to remove the inbox
#    copy: the book is filed, the inbox never drains, and the NEXT pass sees its own leftover as
#    a collision, forever. The test therefore creates the subject folder as the human, under an
#    explicit `umask 022`, exactly as `mkdir` over SSH would — and asserts the inbox folder ends
#    up EMPTY. Set the ACL aside and this test fails.
#
# 2. OWNERSHIP OF THE FILED BOOK, which is what `rename(2)` cannot give you. The dropped file is
#    owned by the human; the filed book must be owned by git-annex, which is the identity holding
#    the fleet annex SSH key and therefore the only one that can replicate the tree (ADR-0028).
#    A plain move would preserve the human's ownership and the filer, running unprivileged, has
#    no CAP_CHOWN to correct it. Asserting the owner of the RESULT is what pins the
#    copy-then-rename; a filer that took the obvious shortcut passes every other assertion here.
#
# 3. THE QUIESCENCE WINDOW AS A DISTINCT STATE. A book still arriving must be skipped SILENTLY —
#    not counted as stuck. `scp` writes in place, so a pass meets half-written files routinely,
#    and a filer that reported those as `no-metadata` would flap the gauge between every pass and
#    the next, which teaches an operator to ignore it. The fixtures are backdated ten minutes so
#    the happy path runs against the REAL 60-second default rather than a shortened test value,
#    and one file is left at the current mtime to hold the window open.
#
# 4. THE METRIC PUBLISHES ALL FOUR REASONS, ALWAYS. A reason that drops to zero must report ZERO
#    rather than vanishing — a vanished series reads as "no data", which is indistinguishable
#    from a dead timer. The last-run timestamp is asserted for the same reason: without it, a
#    clean inbox and a filer that never ran are the same reading. This also exercises the
#    `SupplementaryGroups = [ "node-exporter" ]` decision for real, since the textfile directory
#    is 0775 node-exporter:node-exporter and the filer runs as git-annex.
{ pkgs, self, ... }:
let
  libraryPath = "/var/cache/library";
  booksPath = "${libraryPath}/books";
  inboxPath = "/var/cache/books-inbox";
  stagingPath = "/var/cache/books-staging";
  metricsDir = "/var/lib/prometheus-node-exporter-text-files";

  # Minimal but REAL EPUBs: a stored `mimetype`, a `META-INF/container.xml` pointing at the OPF,
  # and the OPF itself. Built here rather than checked in as binaries precisely so the OPF is
  # readable in review — the empty-title fixture must demonstrably have `<dc:title></dc:title>`
  # and not a MISSING element, because those are different code paths and only one is the AC.
  mkEpub =
    name: opf:
    pkgs.runCommand "fixture-${name}"
      {
        inherit opf;
        passAsFile = [ "opf" ];
        nativeBuildInputs = [ pkgs.zip ];
      }
      ''
        mkdir -p build/META-INF
        printf 'application/epub+zip' > build/mimetype
        cat > build/META-INF/container.xml <<'XML'
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        XML
        cp "$opfPath" build/content.opf
        cd build
        # `mimetype` first and STORED is what makes this a real EPUB rather than a zip of files.
        # Built under a name with an extension, because `zip` appends `.zip` to an archive name
        # that has none — and $out has none.
        zip -X0 book.epub mimetype >/dev/null
        zip -Xr9D book.epub META-INF content.opf >/dev/null
        mv book.epub "$out"
      '';

  package =
    metadata:
    ''
      <?xml version="1.0" encoding="utf-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
          <dc:identifier id="id">fixture</dc:identifier>
    ''
    + metadata
    + ''
        </metadata>
        <manifest><item id="x" href="content.opf" media-type="application/oebps-package+xml"/></manifest>
        <spine/>
      </package>
    '';

  # The ticket's own worked example — and it carries a TRANSLATOR listed FIRST, so "take the
  # first dc:creator" quietly files this under the wrong person's name. Only role-awareness
  # gets `Fuchsia Dunlop` out of it.
  cleanEpub = mkEpub "clean" (package ''
    <dc:title>Invitation to a Banquet</dc:title>
    <dc:creator opf:role="trl" opf:file-as="Translator, A">A Translator</dc:creator>
    <dc:creator opf:role="aut" opf:file-as="Dunlop, Fuchsia">Fuchsia Dunlop</dc:creator>
  '');

  # Present but EMPTY, which is the case the AC names. An absent element is the easy half.
  noTitleEpub = mkEpub "no-title" (package ''
    <dc:title></dc:title>
    <dc:creator>Nobody At All</dc:creator>
  '');

  # Same title+author as cleanEpub, so it derives the identical destination name.
  collideEpub = mkEpub "collide" (package ''
    <dc:title>Invitation to a Banquet</dc:title>
    <dc:creator opf:role="aut">Fuchsia Dunlop</dc:creator>
  '');

  # Every sanitisation hazard that can actually reach the parser, at once: a path separator, a
  # leading dot (which would make the filed book HIDDEN — Stump's scanner skips dotfiles
  # outright, so it would file successfully and never appear in the catalog), a trailing dot,
  # and runs of whitespace including a tab and a hard line break.
  #
  # Note what is NOT here: a C0 control such as `&#x7;`. XML 1.0 forbids those even as character
  # references, so ElementTree rejects the whole document and the file reports as unreadable long
  # before the sanitiser sees it. The control-stripping in `sanitise` is therefore defensive
  # only, and cannot honestly be exercised through a real EPUB.
  nastyEpub = mkEpub "nasty" (package ''
    <dc:title>.  Salt/Fat&#x9;Acid
    Heat . </dc:title>
    <dc:creator opf:role="aut">Samin Nosrat</dc:creator>
  '');

  # EPUB 3 states the role in a refines meta rather than an attribute. Same expectation.
  epub3Epub = mkEpub "epub3" (package ''
    <dc:title>The Book of Trespass</dc:title>
    <dc:creator id="c1">An Illustrator</dc:creator>
    <dc:creator id="c2">Nick Hayes</dc:creator>
    <meta refines="#c1" property="role">ill</meta>
    <meta refines="#c2" property="role">aut</meta>
  '');
in
pkgs.testers.nixosTest {
  name = "book-filer";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        self.nixosProfiles.book-filer
        # The git-annex service module, for its OPTIONS only — `enable` stays false, so its
        # whole `config` (the git-annex user, the package, the init units) is gated off and
        # nothing of it runs. It is here so the profile's "a library repository is declared"
        # assertion has an option to be declared against.
        ../../../modules/nixos/services/git-annex
      ];

      # The identities the profile brokers between. Production gets git-annex + the pinned-GID
      # `library` group from hosts/rk1/library.nix and the git-annex module; declared directly
      # here so the test can exercise the permission boundary without standing up git-annex
      # itself. The human is deliberately NOT in `library` — that is the boundary under test.
      users.groups.library.gid = 977;
      users.groups.git-annex = { };
      users.users.git-annex = {
        isSystemUser = true;
        group = "git-annex";
        extraGroups = [ "library" ];
        home = "/var/lib/git-annex";
        createHome = true;
      };
      users.users.inkpotmonkey = {
        isNormalUser = true;
      };

      # Satisfies the profile's assertion that a library repository is declared. The git-annex
      # module's config is gated on `enable`, so this is an inert option value: no service, no
      # assistant, no Haskell closure dragged into the VM.
      services.git-annex.repositories.library.path = libraryPath;

      # Real node-exporter, so the metrics assertion exercises the actual permission problem:
      # the textfile directory is 0775 node-exporter:node-exporter and the filer runs as
      # git-annex, which reaches it only via the unit's SupplementaryGroups.
      services.prometheus.exporters.node = {
        enable = true;
        enabledCollectors = [ "textfile" ];
        extraFlags = [ "--collector.textfile.directory=${metricsDir}" ];
      };
      systemd.tmpfiles.rules = [
        "d ${metricsDir} 0775 node-exporter node-exporter -"
        # The library tree, as hosts/rk1/library.nix would leave it. `books/` itself is created
        # by the profile's own directory oneshot, so it is NOT pre-made here.
        "d ${libraryPath} 2770 git-annex library -"
      ];

      custom.profiles.book-filer.enable = true;

      # The VM has no /var/cache mount of its own; the profile's RequiresMountsFor would
      # otherwise order against a mount unit that never appears.
      systemd.services.book-filer-directories.unitConfig.RequiresMountsFor = lib.mkForce [ ];
      systemd.services.book-filer.unitConfig.RequiresMountsFor = lib.mkForce [ ];

      # `getfacl` for the ACL assertions.
      environment.systemPackages = [ pkgs.acl ];

      virtualisation.memorySize = 1024;
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("book-filer-directories.service")

    filed = "${booksPath}/Cookery/Invitation to a Banquet - Fuchsia Dunlop.epub"

    with subtest("the directory oneshot sets the default ACL that lets the filer drain the inbox"):
        acl = machine.succeed("getfacl -p ${inboxPath} 2>/dev/null")
        assert "default:group:library:rwx" in acl, acl
        assert "group:library:rwx" in acl, acl
        # The inbox belongs to the human, and the human is NOT in `library` — the corpus is not
        # one accidental `rm` away from replicating a deletion to kelpy.
        assert machine.succeed("stat -c '%U:%G:%a' ${inboxPath}").strip() == "inkpotmonkey:library:2775"
        assert "library" not in machine.succeed("groups inkpotmonkey")

    with subtest("the books root and staging are created with the tree's convention"):
        assert machine.succeed("stat -c '%U:%G:%a' ${booksPath}").strip() == "git-annex:library:2770"
        assert machine.succeed("stat -c '%U:%G:%a' ${stagingPath}").strip() == "git-annex:library:2770"

    # A book already in the library, so the collision fixture has something to collide WITH.
    machine.succeed(
        "install -d -o git-annex -g library -m 2770 ${booksPath}/Food",
        "install -o git-annex -g library -m 664 ${cleanEpub} "
        + "'${booksPath}/Food/Invitation to a Banquet - Fuchsia Dunlop.epub'",
    )

    # Drop everything exactly as a human would over SSH: as the unprivileged account, with a
    # stock umask, creating the subject folders on the way in. `umask 022` is the point — it is
    # what makes the new folders group-UNwritable but for the inherited default ACL.
    machine.succeed(
        "su inkpotmonkey -c 'umask 022; "
        + "mkdir -p ${inboxPath}/Cookery ${inboxPath}/Food ${inboxPath}/Nature; "
        + "cp ${cleanEpub} ${inboxPath}/Cookery/anna-archive-junk-name.epub; "
        + "cp ${nastyEpub} ${inboxPath}/Cookery/nasty.epub; "
        + "cp ${epub3Epub} ${inboxPath}/Nature/epub3.epub; "
        + "cp ${noTitleEpub} ${inboxPath}/Cookery/no-title.epub; "
        + "cp ${collideEpub} ${inboxPath}/Food/collide.epub; "
        + "cp ${cleanEpub} ${inboxPath}/Cookery/notes.pdf; "
        + "cp ${cleanEpub} ${inboxPath}/loose-at-the-root.epub'"
    )

    with subtest("a folder the human creates is NOT group-writable by mode, only by ACL"):
        # The discriminator for the ACL, stated as a fact rather than left implicit: the mode
        # bits alone would deny git-annex the write it needs to unlink, and the drop is the
        # human's, not git-annex's.
        assert machine.succeed("stat -c '%U:%G' ${inboxPath}/Cookery").strip() == "inkpotmonkey:library"
        assert machine.succeed("stat -c '%U' ${inboxPath}/Cookery/no-title.epub").strip() == "inkpotmonkey"

    # Backdate past the REAL 60s quiescence default, so the happy path is tested against the
    # value production runs with rather than a shortened one.
    machine.succeed("find ${inboxPath} -type f -exec touch -d '-10 minutes' {} +")
    # ...and one file left at "now", to hold the window open and prove it is a distinct state.
    machine.succeed("su inkpotmonkey -c 'cp ${cleanEpub} ${inboxPath}/Nature/still-arriving.epub'")

    machine.succeed("systemctl start book-filer.service")

    with subtest("the happy path: renamed from embedded metadata, and the inbox copy is gone"):
        machine.succeed(f"test -f '{filed}'")
        machine.succeed("test ! -e ${inboxPath}/Cookery/anna-archive-junk-name.epub")
        # The translator is listed FIRST in that fixture; taking the first dc:creator would have
        # filed this as "… - A Translator".
        machine.fail("ls ${booksPath}/Cookery | grep -q Translator")

    with subtest("the filed book is owned by git-annex, which rename(2) alone cannot achieve"):
        assert machine.succeed(f"stat -c '%U:%G:%a' '{filed}'").strip() == "git-annex:library:664"
        # The subject folder the filer created carries the tree's setgid convention, not the
        # umask's — plain mkdir would have left it drwxr-sr-x.
        assert machine.succeed("stat -c '%U:%G:%a' ${booksPath}/Cookery").strip() == "git-annex:library:2770"

    with subtest("names are sanitised: no separator, no control chars, no leading dot"):
        machine.succeed("test -f '${booksPath}/Cookery/Salt-Fat Acid Heat - Samin Nosrat.epub'")
        # A leading dot would file successfully and be invisible to Stump, whose scanner skips
        # hidden files — a silent success is the failure mode worth pinning.
        machine.fail("ls -a ${booksPath}/Cookery | grep -q '^\\.[A-Za-z]'")

    with subtest("EPUB 3 states the author in a refines meta rather than an attribute"):
        machine.succeed("test -f '${booksPath}/Nature/The Book of Trespass - Nick Hayes.epub'")

    with subtest("subject folders survive: they are curation, not residue"):
        machine.succeed("test -d ${inboxPath}/Cookery")
        machine.succeed("test -d ${inboxPath}/Food")

    with subtest("missing metadata: left in place, nothing invented"):
        machine.succeed("test -f ${inboxPath}/Cookery/no-title.epub")
        assert machine.succeed("ls ${booksPath}/Cookery | wc -l").strip() == "2"

    with subtest("collision: the existing book is untouched and the incoming one stays put"):
        machine.succeed("test -f ${inboxPath}/Food/collide.epub")
        # Untouched means byte-identical to what was planted, not merely present.
        planted = machine.succeed("sha256sum < ${cleanEpub}").split()[0]
        current = machine.succeed(
            "sha256sum < '${booksPath}/Food/Invitation to a Banquet - Fuchsia Dunlop.epub'"
        ).split()[0]
        assert planted == current, "the collision overwrote the existing book"
        # And it did not quietly suffix its way around the collision either.
        assert machine.succeed("ls ${booksPath}/Food | wc -l").strip() == "1"

    with subtest("unsupported format and a drop with no subject: left, not filed"):
        machine.succeed("test -f ${inboxPath}/Cookery/notes.pdf")
        machine.succeed("test -f ${inboxPath}/loose-at-the-root.epub")

    with subtest("a book still arriving is skipped silently, not counted as broken"):
        machine.succeed("test -f ${inboxPath}/Nature/still-arriving.epub")
        assert "still arriving" in machine.succeed("journalctl -u book-filer.service")

    with subtest("staging is left clean, so a failed copy cannot fill the disk over time"):
        assert machine.succeed("ls -A ${stagingPath} | wc -l").strip() == "0"

    with subtest("the metric reports every reason, including the ones at zero"):
        prom = machine.succeed("cat ${metricsDir}/book-filer.prom")
        for reason, count in [
            ("no-metadata", 1),
            ("collision", 1),
            ("unsupported-format", 1),
            ("bad-path", 1),
        ]:
            expected = f'books_inbox_stuck_files{{reason="{reason}"}} {count}'
            assert expected in prom, f"missing {expected} in:\n{prom}"
        # Without a last-run timestamp, a clean inbox and a dead timer read identically.
        stamp = [l for l in prom.splitlines() if l.startswith("books_inbox_last_run_timestamp_seconds ")]
        assert stamp and int(stamp[0].split()[1]) > 0, prom
        # Written by git-annex into a node-exporter-owned directory — the SupplementaryGroups
        # grant is what makes that possible, and node-exporter must be able to read it back.
        assert machine.succeed("stat -c '%a' ${metricsDir}/book-filer.prom").strip() == "644"

    with subtest("a second pass is a no-op: nothing is re-filed, nothing is double-counted"):
        machine.succeed("systemctl start book-filer.service")
        prom = machine.succeed("cat ${metricsDir}/book-filer.prom")
        assert 'books_inbox_stuck_files{reason="collision"} 1' in prom, prom
        assert machine.succeed("ls ${booksPath}/Cookery | wc -l").strip() == "2"

    with subtest("the timer is armed, so filing happens without anyone starting a unit"):
        machine.succeed("systemctl is-active book-filer.timer")
  '';
}
