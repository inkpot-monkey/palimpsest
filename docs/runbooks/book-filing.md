# Runbook: filing a book into the library

How to get an EPUB into the document library, and what to do when one will not go.

The mechanism is `custom.profiles.book-filer` on rk1b
(`modules/nixos/profiles/book-filer.nix`, palimpsest#144). Read that file's header for *why* it
is shaped this way; this page is for using it.

## Dropping a book

```console
$ scp 'Invitation to a Banquet … Anna'\''s Archive.epub' rk1b:/var/cache/books-inbox/Food/
```

Within two minutes it becomes:

```
/var/cache/library/books/Food/Invitation to a Banquet - Fuchsia Dunlop.epub
```

Three things happen on their own after that: the git-annex assistant adds, commits and
replicates it to kelpy; Stump's watcher scans it into the Books library; and it appears in the
OPDS catalog on the Nomad. None of them need prompting.

**The subject folder is your only input, and it is not optional.** The Stump libraries are
`SERIES_BASED` — one folder is one series — so the folder is a curation decision the filer
deliberately will not make for you. Drop into a new subject by creating the folder first:

```console
$ ssh rk1b mkdir -p /var/cache/books-inbox/Cookery
```

Nested subjects work and are mirrored as-is: `books-inbox/Food/Chinese/x.epub` lands in
`books/Food/Chinese/`.

## What the filer will never do

It never overwrites, never renames around a collision, never deletes, and never guesses a title.
Every failure leaves your file **exactly where you put it**. Nothing is ever lost by dropping a
book that cannot be filed — it just sits there until you deal with it.

## Asking what will happen, before it happens

`book-filer-dry-run` reports what a pass would decide about a file and writes nothing. Use it
instead of guessing from the file, and instead of dropping a book to find out:

```console
$ ssh rk1b "book-filer-dry-run --subject Fiction '/tmp/Violeta … Anna'\''s Archive.epub'"
/tmp/Violeta … Anna's Archive.epub
  title     Violeta [English Edition]: A Novel
  author    Isabel Allende
  filed as  Fiction/Violeta [English Edition]: A Novel - Isabel Allende.epub
  verdict   would file
  note      not under BOOKS_INBOX — subject assumed as 'Fiction'
  note      collision NOT checked: BOOKS_DEST is unset or unreadable from this account …
```

It exits 0 only if every file named would be filed, so it chains:

```console
$ book-filer-dry-run --subject Fiction book.epub && scp book.epub rk1b:/var/cache/books-inbox/Fiction/
```

Point it at a file already **in** the inbox and it uses the real path, so the subject folder, the
arrival window and the collision check all apply — this is the fastest answer to "why is this one
still sitting there?", and it agrees with the stuck-file gauge by construction (both come from the
same `classify` function in `book-filer.py`).

**Mind the two caveats it prints.** `collision NOT checked` means exactly that: the corpus is
`2770 git-annex:library` and the account that drops books is deliberately outside that group, so
a human cannot stat the destination and the collision half of the verdict never ran. Use `sudo`
on rk1b for a verdict that includes it. And `subject assumed` means the subject folder is a guess
from `--subject` (or a placeholder) rather than where the file actually is.

### Do not diagnose an EPUB with a grep

The dry-run exists because the obvious shortcut is wrong. The author role is **namespaced**
metadata, so these two are the same element to a parser and different strings to `grep`:

```xml
<meta     refines="#id-1" property="role">aut</meta>
<opf:meta refines="#id-1" property="role">aut</opf:meta>
```

A grep for `<meta` misses the second spelling, concludes the book declares no author, and predicts
a `no-metadata` rejection for a file that would have filed perfectly well — and the "repair" that
follows edits an irreplaceable original for nothing. Ask the dry-run, which asks the parser the
filer uses.

## Finding out that something is stuck

```console
$ ssh rk1b 'cat /var/lib/prometheus-node-exporter-text-files/book-filer.prom'
books_inbox_stuck_files{reason="no-metadata"} 1
books_inbox_stuck_files{reason="collision"} 0
books_inbox_stuck_files{reason="unsupported-format"} 0
books_inbox_stuck_files{reason="bad-path"} 0
books_inbox_last_run_timestamp_seconds 1755676800
```

`books_inbox_last_run_timestamp_seconds` is the one to check first. All-zero stuck counters mean
"the inbox is clean" only if that timestamp is recent — a stale timestamp means the timer is not
running, and the zeroes are stale too.

The journal has the reason for each individual file:

```console
$ ssh rk1b 'journalctl -u book-filer.service -n 50'
```

## The four reasons, and what to do about each

### `no-metadata`

The EPUB has no usable `dc:title` / `dc:creator` — empty, absent, or only non-author creators
(translators, editors). Also covers a file that will not open as an EPUB at all: a truncated
download, or something with the wrong extension.

First confirm the filer really cannot read it — `book-filer-dry-run <file>` prints the title and
author it resolves, and a grep over the OPF does not (see above). If it genuinely has none, repair
the metadata by hand and re-drop. Deliberately out of scope for the filer — there is no Google
Books or OpenLibrary lookup, by design:

```console
$ nix shell nixpkgs#calibre -c ebook-meta book.epub --title 'Real Title' --authors 'Real Author'
```

Then check it took — with the dry-run, not `ebook-meta`, because the two disagree. `ebook-meta`
reports the author it would *display*, which can be right while the OPF it wrote is still wrong:
`--authors` does not remove a `dc:creator` already in the file, so a book whose only declared role
is `trl` keeps that role and keeps being declined. The dry-run reads it the way the filer does:

```console
$ book-filer-dry-run --subject Fiction book.epub
```

### `collision`

A file already exists at the destination path. Nothing was touched. Usually this means you have
already filed this book — check, and if so just delete the inbox copy yourself:

```console
$ ssh rk1b ls -l '/var/cache/library/books/Food/Invitation to a Banquet - Fuchsia Dunlop.epub'
```

If it is genuinely a *different* book that happens to produce the same `Title - Author`, give one
of them a distinguishing title with `ebook-meta` and re-drop.

This reason also appears in one rarer case: the book was filed successfully but the inbox copy
could not be removed. The journal says so explicitly ("FILED but could not remove the inbox
copy"). The library is correct; delete the leftover.

### `unsupported-format`

Not an EPUB. PDFs, MOBIs and everything else are out of scope — the filer counts them so they do
not sit invisibly, but it will not file them.

- **PDF** — Stump indexes PDFs fine, so filing one by hand into `books/` or `papers/` works. It
  needs `sudo` and the tree's ownership convention:
  ```console
  $ ssh rk1b "sudo install -o git-annex -g library -m 664 /var/cache/books-inbox/Food/x.pdf \
      '/var/cache/library/papers/Food/Title - Author.pdf'"
  ```
- **MOBI / AZW3** — Stump cannot index these at all (`ContentType::from_extension` has no arm
  for them, so its scanner ignores the file entirely). Filing one would put it on disk and in
  the annex while leaving it absent from the catalog and from the device. Convert first:
  ```console
  $ nix shell nixpkgs#calibre -c ebook-convert book.mobi book.epub
  ```
  and drop the EPUB.

### `bad-path`

The file was dropped at the inbox root with no subject folder. Move it into one.

## Checking on the machinery

```console
$ ssh rk1b 'systemctl list-timers book-filer.timer'
$ ssh rk1b 'systemctl status book-filer-directories.service'
$ ssh rk1b 'systemctl start book-filer.service'   # run a pass now instead of waiting
```

`book-filer-directories.service` creates the inbox, the staging directory and the `books/` root,
and sets the ACL that lets the filer drain folders you created. If books are visibly sitting in
the inbox with **nothing** in the journal about them, check that unit first — and check the ACL
survived:

```console
$ ssh rk1b 'getfacl /var/cache/books-inbox'
```

`default:group:library:rwx` must be present. Without it, a subject folder you create is not
group-writable, the filer can read your drop but cannot remove it, and it will re-file the same
book on every pass.

A book dropped in the last 60 seconds is skipped as "still arriving" (`scp` writes in place, so a
pass can meet a half-written file). That is normal and is not counted as stuck.

## Related

- `modules/nixos/profiles/book-filer.nix` — the design and its reasoning
- `docs/runbooks/beets-ingest.md` — the music analogue, which does far more (ADR-0027)
- `docs/runbooks/supernote-koreader-opds.md` — getting the filed book onto the device
- `docs/adr/0031-supernote-document-library-round-trip.md` — why the library is shaped this way
