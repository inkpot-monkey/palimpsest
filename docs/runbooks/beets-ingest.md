# Runbook: the Beets ingest pipeline (rk1b)

The friends' music library (`/var/cache/music`, served by Navidrome) is filled by a
**Beets** pipeline, not by editing the library by hand. Drop audio files into an inbox and
they are fingerprinted, tagged from MusicBrainz, given cover art, de-duped, and filed into
the library automatically; Navidrome's watcher scans them in so they appear for every friend
within seconds. Anything Beets can't confidently identify is quarantined for you to sort by
hand rather than mis-filed.

Served by [`modules/nixos/profiles/beets.nix`](../../modules/nixos/profiles/beets.nix)
(enabled on `rk1b` in [`hosts/default.nix`](../../hosts/default.nix)). Design: ADR-0027.

## The directories (all on the NVMe `/var/cache` subtree)

| Path | Role |
| --- | --- |
| `/var/cache/music-inbox` | **Drop zone.** New files here trigger an import. |
| `/var/cache/music` | The Navidrome library. Confident matches are filed here (`Artist/Album/Track Title`). |
| `/var/cache/music-review` | **Quarantine.** Unmatched / low-confidence / duplicate items land here for manual sorting. |
| `/var/cache/beets` | Beets' own DB (`library.db`), rendered config, and `import.log`. |

All four are owned by the `navidrome` user, and the importer runs as `navidrome` — so filed
tracks are already owned by the account Navidrome reads, with no `chown` step.

## How it flows

1. `beets-import.path` watches the inbox with `DirectoryNotEmpty`. Any new file fires
   `beets-import.service`.
1. The service runs `beet import` at the lowest CPU priority (`Nice=19`) and idle IO class
   (the nice/ionice throttle — courtesy to the co-located monitoring server). Beets:
   - fingerprints every item (Chromaprint/AcoustID) so even **untagged** files are identified,
   - tags from MusicBrainz and fetches cover art,
   - **moves** confident matches into `/var/cache/music`,
   - **skips** items below the confidence threshold and **skips** duplicates of tracks already
     in the library (never doubling them).
1. Whatever Beets leaves behind in the inbox (the skips) is swept into
   `/var/cache/music-review`. This also empties the inbox, so the `.path` unit settles instead
   of re-firing. A burst of drops is drained in one pass.
1. Navidrome's inotify watcher (`Scanner.WatcherEnabled`) picks up the newly filed tracks — no
   manual scan.

## Drop files in

```bash
# On rk1b, as a user who can write the navidrome-owned inbox (e.g. via sudo):
sudo -u navidrome cp -r "/path/to/album" /var/cache/music-inbox/
# or rsync from your workstation into the inbox, then fix ownership:
rsync -a album/ rk1b:/tmp/album/ && ssh rk1b 'sudo mv /tmp/album /var/cache/music-inbox/ && sudo chown -R navidrome:navidrome /var/cache/music-inbox/album'
```

Within a moment `beets-import.service` runs. Check it:

```bash
systemctl status beets-import.service
journalctl -u beets-import.service -n 50
tail -n 50 /var/cache/beets/import.log     # beets' own per-item decisions
```

## Sorting the quarantine

Items in `/var/cache/music-review` were not confidently matched (bad/missing tags **and** no
usable fingerprint, or a duplicate). To retag one interactively and re-file it, run an
**interactive** import as `navidrome`, pointing at the same config:

```bash
sudo -u navidrome env HOME=/var/cache/beets \
  beet -c /run/secrets/rendered/beets-config import /var/cache/music-review/<item>
```

The rendered config does **not** set `quiet` (the automated pipeline passes `-q` on the CLI
instead), so this manual run prompts you to pick a match by hand. Matched items move into the
library; Navidrome scans them in as usual.

## Seeding / reconciling the beets DB with an existing library

Duplicate detection (`duplicate_action: skip`) is **DB-scoped**: beets only knows about tracks
it has imported into `/var/cache/beets/library.db`. Tracks placed in `/var/cache/music` by
another route — the Phase-1 rsync/CLI seed (ADR-0027) — are **not** in that DB, so a later drop
of the same track won't be recognised as a duplicate.

After seeding the library out-of-band, teach the DB about it **once** with an add-only import
(`-A` = register as-is, no MusicBrainz retag / no prompts):

```bash
sudo -u navidrome env HOME=/var/cache/beets \
  beet -c /run/secrets/rendered/beets-config import -A /var/cache/music
```

From then on, duplicates of the seeded tracks are detected like any other. Two caveats: the
active config has `move: yes`, so this run also **normalises the seeded files into the
`Artist/Album` layout in place** (they stay under `/var/cache/music`; Navidrome re-scans). Do
this seed **before** friends build up play history, since the file moves reset path-keyed stats.

## Secrets

The AcoustID fingerprint lookups need an API key: `acoustid_api_key` in
`profiles/navidrome.yaml` (the sops bundle, keyed `admin` + `rk1b`). It is interpolated into
the Beets config via a sops **template**, so the key is never written to the Nix store. Rotate
it the usual way: edit the secret in the `stash` repo, commit + push, `nix flake update secrets`
here, then deploy (see AGENTS.md → *Operational gotchas*).

## Gotchas

- **Ownership.** Files dropped into the inbox as another user won't be importable — the
  service runs as `navidrome`. Copy as `navidrome` or `chown -R navidrome:navidrome` after.
- **Retrigger loop.** The pipeline drains the inbox to empty every run (matches move out,
  rejects sweep to review). If you ever see `beets-import` re-firing in a tight loop, something
  is stuck **undeletable** in the inbox — check permissions on the inbox and the review dir.
- **Network.** Fingerprinting, MusicBrainz, and cover-art all need the network; the unit is
  ordered `After=network-online.target`.
