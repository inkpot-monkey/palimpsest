"""File dropped EPUBs into the document library from their embedded metadata (palimpsest#144).

The music analogue is beets (modules/nixos/profiles/beets.nix, ADR-0027): a drop zone, a
periodic importer, and a library the importer files into. This is the books half, and it is
deliberately far dumber — beets fingerprints audio and queries MusicBrainz because a ripped
track's tags are unreliable; an EPUB's OPF is usually already right. The download is named

    Invitation to a Banquet _ The Story of Chinese Food -- Fuchsia Dunlop -- ... -- Anna's Archive.epub

while `dc:title` / `dc:creator` inside the very same file say `Invitation to a Banquet` /
`Fuchsia Dunlop`. So there is nothing to look up and no network call here at all: the good name
is already in the file, and this script's whole job is to move it to where that name belongs.

WHAT IT WILL NOT DO, and why each one is load-bearing:
  * It never overwrites. Any existing destination path is a collision, full stop.
  * It never suffixes. A `Title - Author.epub.20260820T…` in a SERIES_BASED library is a
    mis-file, not a save. (beets DOES suffix, because it had to DRAIN a level-triggered inbox
    or busy-loop; this runs on a timer, so that pressure does not exist here.)
  * It never deletes, and never treats "same bytes" as permission to remove your copy. This is
    the only thing standing between a downloads folder and an irreplaceable personal corpus.
  * It never guesses a name. Missing metadata means the file stays exactly where you put it.
Every one of those failures leaves the file in the inbox and raises a counter, so the outcome
of a bad drop is always "a human owes this file a decision" — never a silent mis-file.

── Two things about the filesystem that shape the whole script ──────────────────────────────
1. `rename(2)` PRESERVES OWNERSHIP. The dropped file is owned by the human who dropped it, and
   this runs as `git-annex`, which has no CAP_CHOWN — so a plain move would leave the filed book
   owned by a login account inside a tree git-annex must own to replicate. Hence copy-to-staging
   then rename: the staging copy is CREATED by this process, so it is git-annex-owned by
   construction, and the rename into the tree is atomic because staging is on the same
   filesystem. The git-annex assistant watches that tree and will try to add whatever appears in
   it, so it must never see a half-written file — which is exactly what the atomic rename buys.
2. THE SOURCE DIRECTORY MUST BE GROUP-WRITABLE or the inbox never drains. Unlinking a file needs
   write on its CONTAINING directory, not on the file. A subject folder the human mkdirs inherits
   group `library` from the inbox's setgid bit but takes its MODE from their umask — 2755, not
   group-writable — so git-annex could read the drop and never remove it, filing the same book
   forever. The inbox therefore carries a DEFAULT POSIX ACL granting `library` rwx (see the
   profile's directory oneshot); this script only relies on the result.

Configuration arrives by environment, all required except BOOKS_METRICS_DIR:
    BOOKS_INBOX          drop zone root; subject folders are its children
    BOOKS_DEST           the `books/` root inside the library tree
    BOOKS_STAGING        git-annex-owned scratch on the same filesystem as BOOKS_DEST
    BOOKS_GROUP          group the filed files/dirs must carry
    BOOKS_QUIESCE_SECS   ignore anything modified more recently than this
    BOOKS_METRICS_DIR    node-exporter textfile dir; empty or absent disables metrics
"""

import os
import shutil
import sys
import time
import zipfile
from pathlib import Path
from xml.etree import ElementTree

# OPF/EPUB namespaces. `dc` is where the metadata actually lives; `opf` carries the role
# attribute that distinguishes an author from a translator or illustrator.
DC = "http://purl.org/dc/elements/1.1/"
OPF = "http://www.idpf.org/2007/opf"
CONTAINER = "urn:oasis:names:tc:opendocument:xmlns:container"

# Every reason a file can be left behind. Enumerated (rather than accumulated as encountered)
# so the metric always publishes all four series: a reason that drops to zero must report ZERO,
# not vanish. A vanishing series reads as "no data" on a dashboard, which is indistinguishable
# from a dead timer — the exact silent-failure shape this fleet keeps getting bitten by.
REASONS = ("no-metadata", "collision", "unsupported-format", "bad-path")

# The filed name is capped so it survives any filesystem (255 BYTES is the common limit; 200
# leaves room and keeps `ls` readable). Subtitles are the reason this is not theoretical.
MAX_BASENAME_BYTES = 200

# Directories in the library tree match the tree's convention: setgid, group-confined, no
# world access (hosts/rk1/library.nix). Files are 664 — the world bit is moot inside a 2770
# parent, but it matches what the ticket asked for and what git-annex writes elsewhere.
DIR_MODE = 0o2770
FILE_MODE = 0o664


def log(message):
    """Journal line. Everything this script says is operator-facing, so it all goes to stderr."""
    print(f"book-filer: {message}", file=sys.stderr, flush=True)


def read_epub_metadata(path):
    """Return `(title, author)` from the EPUB's OPF, or `(None, None)` if it cannot be had.

    The OPF's location is not fixed by the spec — `META-INF/container.xml` names it — so this
    follows the same two hops a reader app does. A truncated or corrupt file raises out of
    `zipfile` (a partial zip has no end-of-central-directory record), which is the BACKSTOP for
    a drop still in flight: the quiescence window is the primary gate, and this catches a
    transfer that stalled for longer than the window.
    """
    with zipfile.ZipFile(path) as zf:
        container = ElementTree.fromstring(zf.read("META-INF/container.xml"))
        rootfile = container.find(f".//{{{CONTAINER}}}rootfile")
        opf_path = rootfile.get("full-path") if rootfile is not None else None
        if not opf_path:
            return None, None
        opf = ElementTree.fromstring(zf.read(opf_path))

    def text_of(element):
        return (element.text or "").strip()

    titles = [t for t in opf.iter(f"{{{DC}}}title") if text_of(t)]
    creators = [c for c in opf.iter(f"{{{DC}}}creator") if text_of(c)]
    if not titles or not creators:
        return None, None

    # Prefer a creator explicitly marked as the author. EPUB 2 says so with an `opf:role`
    # attribute; EPUB 3 moved it to a `<meta refines="#id" property="role">` sibling. Both are
    # common in the wild, so both are honoured — and if NOTHING declares a role, the first
    # creator wins, which is the overwhelmingly common case and the right answer in it.
    refined_roles = {
        m.get("refines", "").lstrip("#"): text_of(m)
        for m in opf.iter(f"{{{OPF}}}meta")
        if m.get("property") == "role"
    }

    def is_author(creator):
        if creator.get(f"{{{OPF}}}role") == "aut":
            return True
        return refined_roles.get(creator.get("id", "")) == "aut"

    roles_declared = any(
        c.get(f"{{{OPF}}}role") or refined_roles.get(c.get("id", "")) for c in creators
    )
    author = next((c for c in creators if is_author(c)), None)
    if author is None and roles_declared:
        # Roles ARE declared but none is `aut` — a collection of translators/editors with no
        # author named. Guessing here would put an editor's name on a book cover, so decline.
        return None, None

    # Display text, deliberately NOT `opf:file-as`. `file-as` is the sort key ("Dunlop,
    # Fuchsia"); the filed name wants the human form ("Fuchsia Dunlop"), which is what the
    # ticket's own worked example asks for.
    return text_of(titles[0]), text_of(author if author is not None else creators[0])


def sanitise(text):
    """Make `text` safe as one path component. Conservative: it may only ever REMOVE trouble."""
    text = text.replace("/", "-")
    # Drop C0/C1 controls and NUL — legal in a Linux filename and a menace everywhere else (this
    # name reaches an e-ink reader, a WebDAV client and an OPDS feed). Whitespace is KEPT rather
    # than dropped so the collapse below turns it into a single space: deleting it instead would
    # weld words together, turning a `<dc:title>` wrapped across two lines into "AcidHeat".
    text = "".join(ch for ch in text if ch.isprintable() or ch.isspace())
    text = " ".join(text.split())
    # A leading dot would hide the book from Stump, whose scanner skips hidden files outright
    # (core/src/filesystem/common.rs `is_hidden_file`) — it would file successfully and never
    # appear in the catalog. Trailing dots/spaces are the Windows/SMB footgun.
    return text.strip(". ")


def filed_name(title, author):
    """`<Title> - <Author>.epub`, sanitised and byte-capped, or None if nothing survives."""
    stem = sanitise(f"{sanitise(title)} - {sanitise(author)}")
    if not stem:
        return None
    budget = MAX_BASENAME_BYTES - len(".epub")
    encoded = stem.encode("utf-8")
    if len(encoded) > budget:
        # Cut on a byte boundary and discard whatever partial codepoint that lands in, then
        # re-strip: the truncation can expose a new trailing space or dot.
        stem = encoded[:budget].decode("utf-8", errors="ignore").rstrip(". ")
        if not stem:
            return None
    return f"{stem}.epub"


def ensure_dir(path):
    """Create `path` (and parents) inside the tree with the tree's own convention.

    `os.makedirs(mode=…)` is not enough: the mode is masked by the umask and only applied to
    the LEAF, so intermediate subject folders would land with whatever the process umask says.
    Each component is therefore chmod'd explicitly — including the setgid bit, which is what
    keeps group `library` flowing down to everything git-annex and Stump must later read.
    """
    missing = []
    probe = path
    while not probe.exists():
        missing.append(probe)
        probe = probe.parent
    for component in reversed(missing):
        component.mkdir()
        os.chmod(component, DIR_MODE)


def file_book(source, destination, staging):
    """Copy `source` into place as `destination`, then remove `source`. Returns True on success.

    Ordering is chosen for how it FAILS. The copy lands in staging, gets its final mode, and is
    renamed into the tree atomically — so the git-annex assistant, which watches that tree, sees
    either nothing or a complete file, never a partial one. The source is unlinked only after
    that rename has succeeded. If the unlink then fails, the book is already correctly filed and
    the next run sees the leftover as a COLLISION: it stays in the inbox and is counted, which is
    a loud, safe, human-resolvable end state rather than a silent double-file.
    """
    ensure_dir(destination.parent)
    scratch = staging / f".{os.getpid()}-{destination.name}"
    try:
        # copyfile, not copy2: the destination's mtime should be when it was FILED. It is a new
        # object in the library, and the download's timestamp is an artifact of the download.
        shutil.copyfile(source, scratch)
        os.chmod(scratch, FILE_MODE)
        os.rename(scratch, destination)
    finally:
        # Never leave scratch behind — it shares a filesystem with the library and a failed run
        # that leaks copies would fill the NVMe silently.
        if scratch.exists():
            scratch.unlink()

    try:
        source.unlink()
    except OSError as exc:
        log(
            f"FILED but could not remove the inbox copy of {source}: {exc}. "
            "The book is in the library; the leftover will report as a collision next run."
        )
        return False
    return True


def write_metrics(metrics_dir, stuck, started):
    """Publish the gauges, best-effort — never fail the run over telemetry.

    Best-effort in the same sense as monitoring/secret-expiry.nix: written only where the
    node-exporter textfile directory actually exists, so enabling this profile on a host without
    monitoring-exporters degrades to journal-only instead of erroring every two minutes.

    The timestamp is not decoration. Without it, a DEAD TIMER and a CLEAN INBOX are the same
    reading — zero stuck files — and the failure that matters most here is the one where nothing
    is running at all.
    """
    if not metrics_dir:
        return
    directory = Path(metrics_dir)
    if not directory.is_dir():
        log(f"metrics dir {directory} absent — skipping textfile metric")
        return

    lines = [
        "# HELP books_inbox_stuck_files Files in the book inbox this filer will never move, by reason (palimpsest#144).",
        "# TYPE books_inbox_stuck_files gauge",
    ]
    lines += [
        f'books_inbox_stuck_files{{reason="{reason}"}} {stuck[reason]}'
        for reason in REASONS
    ]
    lines += [
        "# HELP books_inbox_last_run_timestamp_seconds Unix time the book filer last completed a pass.",
        "# TYPE books_inbox_last_run_timestamp_seconds gauge",
        f"books_inbox_last_run_timestamp_seconds {started}",
    ]

    # Write-then-rename: node-exporter reads this directory on its own schedule and a partial
    # .prom is a parse error that discards every series in the file.
    target = directory / "book-filer.prom"
    scratch = directory / f".book-filer.{os.getpid()}"
    try:
        scratch.write_text("\n".join(lines) + "\n")
        os.chmod(scratch, 0o644)
        os.rename(scratch, target)
    except OSError as exc:
        log(f"could not publish metrics to {target}: {exc}")
        if scratch.exists():
            scratch.unlink()


def main():
    inbox = Path(os.environ["BOOKS_INBOX"])
    dest_root = Path(os.environ["BOOKS_DEST"])
    staging = Path(os.environ["BOOKS_STAGING"])
    quiesce = int(os.environ["BOOKS_QUIESCE_SECS"])
    metrics_dir = os.environ.get("BOOKS_METRICS_DIR", "")

    started = int(time.time())
    stuck = dict.fromkeys(REASONS, 0)
    filed = 0

    for source in sorted(p for p in inbox.rglob("*") if p.is_file()):
        relative = source.relative_to(inbox)

        # Hidden files are somebody else's business — an in-flight rsync temp, an editor
        # swapfile, a macOS `._` turd. Skipped silently and NOT counted: they are not files a
        # human is waiting on, and counting them would make the gauge cry wolf.
        if any(part.startswith(".") for part in relative.parts):
            continue

        # THE QUIESCENCE GATE, and the reason it comes before every other check. `scp` writes in
        # place with no temp-and-rename, so a run can meet a half-arrived book — whose OPF is
        # unreadable, and which would therefore report as `no-metadata` and bump the gauge, only
        # to file cleanly two minutes later. That would teach you to ignore the gauge. Keeping
        # "still arriving" and "genuinely broken" as distinct states is the whole point.
        if started - source.stat().st_mtime < quiesce:
            log(f"still arriving, leaving for the next pass: {relative}")
            continue

        # The subject folder IS the curation decision (ADR-0031: the libraries are SERIES_BASED,
        # one folder is one series), and it is the one input only a human can supply. A book
        # dropped at the inbox root has not been given a subject, and filing it to the `books/`
        # root would create a seriesless orphan in a library whose scan pattern is immutable.
        if len(relative.parts) < 2:
            log(f"no subject folder (drop it in books-inbox/<Subject>/): {relative}")
            stuck["bad-path"] += 1
            continue

        if source.suffix.lower() != ".epub":
            # Out of scope by decision, not oversight — but COUNTED, so a PDF you meant to file
            # surfaces as "needs a human" instead of sitting in the inbox invisibly forever.
            log(f"not an EPUB, leaving in place: {relative}")
            stuck["unsupported-format"] += 1
            continue

        try:
            title, author = read_epub_metadata(source)
        except (zipfile.BadZipFile, KeyError, ElementTree.ParseError, OSError) as exc:
            log(f"unreadable EPUB, leaving in place: {relative} ({exc})")
            stuck["no-metadata"] += 1
            continue

        if not title or not author:
            log(
                f"no usable dc:title/dc:creator, leaving in place: {relative} "
                "(repair with `ebook-meta` and re-drop)"
            )
            stuck["no-metadata"] += 1
            continue

        name = filed_name(title, author)
        if not name:
            log(f"metadata sanitises to an empty name, leaving in place: {relative}")
            stuck["no-metadata"] += 1
            continue

        destination = dest_root / relative.parent / name
        if destination.exists():
            log(
                f"destination exists, refusing to overwrite: {relative} -> {destination}"
            )
            stuck["collision"] += 1
            continue

        try:
            if file_book(source, destination, staging):
                filed += 1
                log(f"filed {relative} -> {destination.relative_to(dest_root)}")
        except OSError as exc:
            log(f"failed to file {relative}: {exc}")
            stuck["no-metadata"] += 1

    total_stuck = sum(stuck.values())
    if filed or total_stuck:
        log(f"pass complete: filed {filed}, left {total_stuck} for a human {stuck}")
    write_metrics(metrics_dir, stuck, started)


if __name__ == "__main__":
    main()
