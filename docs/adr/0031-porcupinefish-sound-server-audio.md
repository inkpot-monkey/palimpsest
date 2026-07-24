# porcupineFish becomes a sound-server audio host: Snapcast owns the DAC, Music Assistant drives Navidrome to it

porcupineFish today is a single-purpose Spotify Connect box: `spotifyd` opens the
HiFiBerry DAC (`hw:sndrpihifiberry`) directly and is the *only* audio process.
Two goals broke that model at once — play the self-hosted **Navidrome** library out
of the speakers, and get a "Spotify-Connect-for-Navidrome" experience (control from a
phone, audio out the Pi). A raw ALSA hardware device can be held by exactly **one**
process at a time, so "add a second source" is not additive on this design — it forces
a decision about *what owns the device*. Compounding it: this box's defining operational
pain is the **SoC I²S clock wedge**, whose known trigger is churning the PCM device
(open/close), recoverable only by a cold power-cycle
([RUNBOOK-audio-silence.md](../../hosts/porcupineFish/RUNBOOK-audio-silence.md)). Any
"share the device" scheme that repeatedly opens/closes the PCM (ALSA `dmix`, swapping
which app holds the card) actively *feeds* the wedge.

## Decision

**A persistent sound-server owns the DAC. `snapclient` on the Pi becomes the sole,
always-on ALSA opener; every source feeds `snapserver` instead of the hardware. Spotify
becomes a snapserver `librespot` stream (retiring standalone `spotifyd`); Navidrome
reaches the speakers via **Music Assistant** on rk1b, which drives the Pi's snapserver as
an external server. The Pi stays a self-contained audio appliance.**

- **Snapcast on the Pi, single persistent opener (fewer clock transitions, not a full cure).**
  `snapserver` + `snapclient` run *on the Pi*. snapclient is the sole ALSA opener — but note
  (verified on deploy 2026-07-24) it **closes the PCM ~5s after playback stops** and reopens on
  the next chunk; it does *not* hold the clock open 24/7 by default. This still collapses the old
  churn (N competing apps opening/closing per track) into one consistent opener whose reopen was
  verified working live. The full "always-on clock" idea from [porcupinefish-moode-learnings] would
  need snapserver to feed continuous silence (a `process` silence source + a `meta:///Spotify/Silence`
  stream the client sits on). **Decided against building it (2026-07-24):** the forked Volumio review
  found Volumio's Spotify-Connect path (= this one) does *not* wedge and that its silence-keepalive
  was only ever an unshipped feature request — so the idle-close (which only happens when nobody is
  listening) is accepted, and the silence-keepalive is deferred to *if a real device-wide wedge
  recurs*.

- **Self-contained Pi (snapserver local), not a dumb endpoint.** snapserver runs on the
  Pi so Spotify and the audio decisions stay on the audio box and do not depend on rk1b
  being up. Music Assistant runs *elsewhere* (rk1b) and feeds *in*. Rejected: snapserver
  on rk1b with the Pi as snapclient-only — leaner Pi, but it moves Spotify into MA and
  makes the appliance depend on another host to play anything.

- **Spotify = a snapserver `librespot` stream; retire `services.spotifyd`.** spotifyd
  cannot feed snapserver (it has no pipe backend), so it is replaced by snapserver's
  built-in `librespot` stream (native `--backend pipe` → snapserver, the same clean path
  Volumio uses via vollibrespot). The Connect endpoint still advertises over zeroconf as
  "porcupineFish" and appears in the Spotify app unchanged; bitrate/normalisation/device
  name port over. **Lost:** the bespoke disconnect-watchdog and the `volume_controller=alsa`
  wrapper — the watchdog is reinstatable as a journal-tailing unit if the silent-wedge
  recurs, and volume moves to snapclient (below). The `spotify/password` secret can be
  dropped (zeroconf needs no stored credentials).

- **Navidrome → speakers via Music Assistant on rk1b, controlled through Home Assistant.**
  MA is the only component that speaks Subsonic/OpenSubsonic *and* outputs to Snapcast, so
  it is the "brain." It runs on **rk1b, the media node — co-located with Navidrome and the
  git-annex library it scans and streams** (which is what matters most; MA is media, and the
  media node has the disk). Home Assistant runs on **rk1a** (the voice node, ADR-0027) and
  controls MA over the tailnet — a lightweight API link, not a co-location requirement. MA
  uses its **external-snapserver** mode: it dynamically creates `tcp://` streams on the Pi's
  snapserver via the JSON-RPC control port (1705) and pushes audio to them — the Pi's
  snapserver needs no pre-defined MA stream. One snapserver hosts both the static
  `librespot` stream and MA's dynamic streams; the local snapclient switches between them.

- **Two control planes, deliberately not unified.** Spotify is driven by the native Spotify
  app (→ the Pi's librespot stream); Navidrome by Home Assistant/MA. Each source keeps its
  best-in-class remote and Spotify keeps working if rk1b/MA is down. Rejected: routing
  Spotify *through* MA for one pane of glass — it would surrender "porcupineFish in the
  Spotify app" and inherit MA's rougher Spotify handling.

- **Hardware-mixer volume, preserved.** snapclient drives the PCM512x "Digital" hardware
  mixer (`--mixer=hardware`) so attenuation stays in the DAC at full bit-depth — the same
  fidelity rationale [hifi.nix](../../modules/nixos/profiles/pi/hifi.nix) documents for
  `volume_controller=alsa`, now expressed through snapclient.

- **Snapcast pinned to 0.34.0.** MA 2.9.6 bundles and tests against snapserver **0.34.0**
  (`SNAPCAST_VERSION=0.34.0` in MA's `Dockerfile.base`); nixpkgs ships 0.35.0, one minor
  ahead of MA's tested version, unverified, and touching the dynamic `Stream.RemoveStream`
  path MA drives (0.30 was documented-broken, 0.32 broke MA per snapcast#1410). We pin the
  Pi's `snapcast` to 0.34.0 via overlay for both snapserver and snapclient, and bump only
  deliberately + tested. MA's snapcast *provider* is flagged "unmaintained" upstream, which
  reinforces holding both ends on the known-good pairing.

- **Collaborative shared queue via the MA Party plugin.** The actual goal is a "Spotify Jam on
  your own library": one person plays the Navidrome library on the speaker, and friends **join by
  scanning a QR code** — a no-account, no-app phone web view — to search the library and **add to
  the one shared queue**, with vote-to-skip / dedup / rate-limiting. MA's first-party **Party
  plugin** (2.8+) delivers exactly this over the same Navidrome+Snapcast setup, which is why MA is
  the right brain for this goal over the alternatives (Mopidy+Party is an unpackaged DIY equivalent;
  Navidrome Jukebox needs Navidrome on the Pi contending for the DAC and has no guest join). The
  Party join is anonymous (a "party" badge, not per-person identity); the host controls playback as
  an authenticated MA admin.

- **MA configured fully declaratively over its HTTP API — no manual UI onboarding.** MA (schema 31)
  requires a JWT on every API call, and its config is normally UI-entered and stored (Fernet-keyed)
  in `settings.json`. But MA's own HTTP endpoints make full bootstrap scriptable: `POST /setup`
  creates the first admin user when none exist and returns a token (else `POST /auth/login`), and
  `POST /api` (JSON-RPC, admin role) configures providers. So a post-start oneshot (pure stdlib,
  mirroring Navidrome's `provisionUsers`) creates MA's admin from sops, then ensures the
  **opensubsonic** (Navidrome), **snapcast** (external server = the Pi), and **party** providers
  exist. Idempotent + reproducible from scratch — no imperative-island UI step.

- **MA has its own admin *account*; it cannot reuse Navidrome *users*.** MA's only login providers
  are its builtin user store and Home Assistant OAuth — there is no Subsonic/LDAP/external-auth
  delegation, so MA logins are a *separate* user base from Navidrome. MA therefore gets its own
  admin account (username `provisioner`), distinct from the Navidrome `music-assistant` service
  account — but the two share the one `music-assistant` sops secret as their password *value*
  (reuse within a single trust boundary: same file, host, and provisioner), avoiding a second secret.

- **MA reads Navidrome as a dedicated `music-assistant` account**, created by the same oneshot via
  Navidrome's admin API (a service credential, kept out of the friend `users` map) — least-privilege,
  and the account *is* the speaker's listening identity on the Navidrome side (see stats, below).

## Stats: communal speaker, ListenBrainz as the unified truth

porcupineFish is modelled as a **communal speaker** (a place, not a person). MA-driven
Navidrome plays are captured by opting into MA's `subsonic_scrobble` plugin, which
scrobbles back to Navidrome on 90%-played — populating Navidrome's native play counts,
**attributed to the single `music-assistant` account**. Navidrome then forwards those
plays to **ListenBrainz**; MA's own ListenBrainz plugin is left *off* to avoid a
double-count. Spotify plays (which never touch MA) reach ListenBrainz via its native
Spotify importer. Result: Navidrome's own stats UI works for communal listening, and
ListenBrainz is the single cross-source ("Spotify + Navidrome") history. Stats are a
**bolt-on**, independent of the audio path, and can land after playback works.

**Deliberately not built: per-person attribution for speaker plays.** A single shared MA
service account means Navidrome sees one identity for every speaker play; it cannot tell
who is driving. Per-person is only reachable on the *ListenBrainz* side (never Navidrome
native), and only if each human (a) has their own MA user and (b) controls the speaker
through their own authenticated MA/HA session rather than a shared remote — a materially
more complex control model. Recorded as a future improvement, not a requirement. Per-person
stats still happen naturally today whenever someone plays on *their own* device as
themselves.

## Consequences

- **`hifi.nix` is largely rewritten.** The `services.spotifyd` block, its watchdog, and its
  ALSA volume wiring go away, replaced by snapserver stream config + snapclient. The
  HiFiBerry hardware profile (`hifiberry.nix`) is unchanged — the card, master-mode overlay,
  and mixer persistence still apply.
- **New/changed on the Pi:** a snapcast 0.34.0 overlay; snapserver (with a `librespot`
  stream) + snapclient units; firewall — LAN keeps only Spotify Connect discovery (mDNS
  UDP 5353 + the librespot zeroconf TCP port), `tailscale0` gains snapserver control (1705)
  - MA's dynamic high-TCP range scoped to rk1b, and 1704 stays loopback. Nothing new to
    persist under impermanence (snapcast is stateless; the librespot audio cache is
    disposable).
- **New on rk1b:** a `music-assistant` profile (`services.music-assistant` + the provisioning
  oneshot); MA state on the NVMe at `/var/cache/music-assistant`, mount-gated
  (`RequiresMountsFor=/var/cache`) like Navidrome; a dedicated `music-assistant` entry in the
  Navidrome `users` sops map.
- **New secrets:** the `music-assistant` Navidrome password (in the Navidrome `users` map).
  The `spotify/password` secret is retired. Remember the secrets-repo commit + push +
  `nix flake update secrets` before deploy.
- **Version coupling is now load-bearing.** MA 2.9.x ↔ snapserver 0.34.0 is a tested pair;
  bumping either end is a deliberate, test-after change, and the MA snapcast provider being
  upstream-unmaintained means this coupling should be watched.
- **One known rough edge:** switching streams via snapcast's *own* controls (not through MA)
  can desync MA's view of which stream its client is on until nudged. Livable; prefer
  switching from MA when you want MA playback.
- **Deploy ordering:** the Pi (snapserver reachable on 1705 over tailscale) should be up
  before MA's provisioning oneshot on rk1b runs, or the snapcast-provider save will fail its
  first connection (the oneshot is idempotent, so a re-run recovers).

## Follow-up — auto-follow switcher + unified volume (#96, implemented 2026-07-24)

The base design left two gaps that made switching sources manual/broken; both are now closed
on porcupineFish (`modules/nixos/profiles/pi/hifi.nix` + `snapcast-stream-switcher.py`).

- **Auto-follow arbiter (A).** snapcast 0.34 does not auto-follow the active stream, so playing
  in the *other* source left the group bound to the old stream → silence. A small systemd
  watcher (`snapcast-stream-switcher.service`) subscribes to the control API and, on a
  **debounced `idle → playing` edge**, `Group.SetStream`s the connected client's group to the
  stream that just started — Volumio's volatile-state model (event-driven off stream *status*,
  not PCM-silence sniffing). Debounced so a between-tracks idle dip never flaps output;
  last-activated-wins with a fixed priority tiebreak; it also hands the speaker to a
  still-playing source when the focused one is paused. No manual `Group.SetStream` anywhere.

- **Volume model B, not A (single hardware master).** snapclient's HiFiBerry "Digital" hardware
  mixer is the single gain stage; MA drives it, and librespot is pinned full-scale with
  `--volume-ctrl fixed` so the Spotify stream never adds a second, hidden gain (the old
  "on full but quiet after switching" drift). **Model A — bridging the Spotify app slider onto
  the hardware mixer at full fidelity — was ruled out as architecturally unavailable, not merely
  fiddly:** librespot 0.8.0's Connect layer (`spirc.rs` `set_volume`) *unconditionally* applies
  the app's volume to its softvol mixer **and** emits the volume event; there is no
  report-without-attenuate for the pipe backend (verified against the v0.8.0 source), so an
  `--onevent` bridge would double-attenuate. Consequence: the Spotify **app** slider is not the
  master — volume is set via MA / snapweb / Home Assistant. This is the fallback the issue
  sanctioned ("ship B rather than block").
