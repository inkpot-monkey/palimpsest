# Navidrome is the friends' music platform, and the RK1 nodes swap LLM for voice + media

A shared, multi-user music platform for a handful of **non-technical friends** was
the goal. Funkwhale is the obvious fediverse answer, but it lost on the one axis
that decides this project — *will non-technical friends actually use it*: it is
**not in nixpkgs** (never merged, a heavyweight Django + Celery + PostgreSQL +
Redis stack behind an out-of-tree module or containers), its **mobile clients are
thin/beta** (essentially web-only on iOS), and the music fediverse it would join
is **tiny and fragile** (~52 instances / ~2,792 users in 2026, with the lead
maintainer stepped back to critical-fixes-only). Crucially, *federation is
invisible to the friends* — the value it would justify its cost with is a value
they never see. The whole platform therefore only needed the *shared-library,
per-user-profile* shape, which is Navidrome's native happy path. Hosting it, in
turn, forced a fleet rebalance, because the media library needs disk the LLM node
doesn't have.

## Decision

**Adopt Navidrome (not Funkwhale) as the friends' music platform, tailnet-first,
with a Beets ingest pipeline — and repurpose the RK1 nodes so the media workload
lands where the disk is.**

- **Platform** — `services.navidrome` (native nixpkgs module, single Go binary,
  SQLite). One **shared communal library**; every friend gets an account with
  their own favourites/playlists/history. Friends listen through the **Subsonic
  client ecosystem** (Amperfy on iOS, Symfonium on Android) or the web player —
  the ecosystem reach that Funkwhale lacks.
- **RK1 role swap** — the local Qwen MoE on `rk1a` is retired (its sole consumer,
  openclaw, is disabled — see below), freeing the node. **`rk1a` becomes the voice
  node** (Home Assistant + Wyoming, moved off `rk1b`, fresh state — it was a PoC).
  **`rk1b` becomes the media + monitoring node**: the music stack lives on its
  512 GB NVMe (`/var/cache` subtree) alongside the monitoring server it already
  hosts. Voice does not need disk, so it fits `rk1a`'s 29 GB eMMC without an NVMe;
  media does, so it stays on `rk1b`.
- **Access** — tailnet-only, fronted by kelpy's Caddy under `internal_only`
  (`music.<domain>`), exactly like Home Assistant. Friends join the tailnet to
  listen. **Pivot condition:** if user-testing shows Tailscale onboarding is too
  much friction for non-technical friends, expose *only* the Navidrome vhost
  publicly (the rest of the fleet stays `internal_only`) — public Navidrome is a
  categorically smaller surface than public Funkwhale would have been.
- **Admin** — declarative via sops-nix: `ND_DEVAUTOCREATEADMINPASSWORD` (through
  the module's `environmentFile`) bootstraps the `admin` user on first run.
  Friends are created on demand in the admin UI (Navidrome has no self-signup, by
  design; hand-provisioning is *better* onboarding for non-technical people than a
  signup flow).
- **Ingest** — files land in `/var/cache/music-inbox`; a systemd path unit fires a
  `nice`/`ionice`-throttled `beet import` that fingerprints (Chromaprint/AcoustID),
  tags from MusicBrainz, fetches art, de-dupes, and files into `/var/cache/music`;
  Navidrome's inotify watcher auto-scans. Confident matches auto-file; uncertain
  ones quarantine to `music-review/` for manual sorting.

## Why Navidrome, and the explicit no-s

- **No Funkwhale.** Packaging rot (out of tree), a heavy multi-process stack, weak
  mobile clients, and a federation network too small and unstable to be worth its
  cost — none of which a non-technical friend would trade a worse listening
  experience for.
- **No federation.** The friends are a closed, known group; ActivityPub buys them
  nothing and would force public exposure and a public Django surface.
- **No in-app upload / no forked Subsonic API.** The Subsonic/OpenSubsonic API is
  deliberately read-only, and the app-store clients only speak the *standard* spec
  — a forked upload endpoint would be invisible to them, defeating the ecosystem
  that is Navidrome's whole advantage. Upload is a side-channel (Phase 2), not a
  fork.
- **No self-signup.** Admin-provisioned accounts; see above.

## Why retire the local LLM and move voice to rk1a

`rk1a` has no NVMe (29 GB eMMC), so it *cannot* host the media library — but the
freed node is exactly what "balance load onto rk1a" wants. Voice (HA + Wyoming's
small base-int8 Whisper) is light on disk and fits the eMMC once the 15.4 GB GGUF
is gone. Moving voice there — rather than piling the new media workload onto the
already-busy `rk1b` — also **physically separates latency-sensitive real-time STT
(rk1a) from Beets fingerprinting / transcode CPU (rk1b)**, which is cleaner than
throttling them against each other on one box. The local MoE (~10-15 tok/s) was
marginal, and its only consumer (openclaw's `primary` model) is being disabled;
with no consumer, no cloud substitute is needed. openclaw can return later pointed
at a funded cloud model.

## Consequences

- **Phased.** Phase 1 is the above minus friend-upload: you seed the library via
  rsync/CLI, friends listen. **Phase 2** adds friend contribution — a maubot
  WhatsApp-bot plugin (a friend texts a song → bridged to Matrix → downloaded into
  the Beets inbox → filed → confirmed back over WhatsApp) and, if wanted, a
  FileBrowser drop UI. Deferred because it is the only net-new custom code and the
  riskiest piece (WhatsApp re-encoding, routing), and the platform's core value —
  friends listening to a well-organised shared library — does not depend on it.
- **Blast radius of the LLM removal** — `settings.nodes`/`services` (`localLlmA`,
  `openclaw` entries), `litellm.nix` (`qwen-general` gateway + fallback),
  `kelpy/configuration.nix` (openclaw agent block), `hosts/rk1/{llm.nix, common.nix import}`, the `llama-cpp` curl overlay, and `hosts/rk1/README.md` all shed LLM
  config. openclaw's uptime monitor drops with its service entry. This retirement
  **supersedes [ADR-0010](0010-rk1-llm-cpu-serving.md)** (RK1 LLM CPU serving).
- **Deploy ordering matters** — HA must be running on `rk1a` before
  `home.origin` is flipped `rk1b → rk1a` (else Caddy proxies voice to a dead
  upstream). See the migration plan.
- **Shared-fate disk** — the music library shares `rk1b`'s 349 GB `/var/cache`
  with telemetry and paperless, uncapped by choice; watched via existing node-disk
  metrics, revisited only if pressure appears.
- **New secrets** — `navidrome_admin_password` and `acoustid_api_key` (sops;
  remember the secrets-repo commit + push + `nix flake update secrets` before
  deploy).
- **Node roles changed** — `rk1a`: LLM → voice; `rk1b`: voice → media + monitoring.
  Both stay `always-on`, so the presence model (ADR-0026) is unaffected. The
  `hosts/rk1/README.md` role descriptions need updating as part of the work.
