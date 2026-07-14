# Future upgrade: DSP / room correction (CamillaDSP) — DEFERRED

**Status (2026-07-06): deliberately NOT doing this yet.** This doc banks the research so
the decision isn't re-litigated and the future upgrade is a recipe, not a fresh
investigation. Came out of studying the [moOde](https://github.com/moode-player/moode)
player (see [`RUNBOOK-audio-silence.md`](./RUNBOOK-audio-silence.md) and the
`porcupinefish-moode-learnings` memory).

## The decision and why it's deferred

CamillaDSP would sit in the ALSA path (`spotifyd → alsa_cdsp plugin → CamillaDSP → DAC`)
and could apply parametric EQ, room correction (FIR convolution), a woofer-protecting
high-pass, and loudness compensation.

**~80% of its value is room correction.** Without a room measurement the rest is either
_blind_ (speaker EQ with no reliable Titus EZ curve = guessing), _marginal_ (phase/FIR on
a fixed passive crossover), or _already covered_ (spotifyd's ReplayGain handles loudness
leveling). So it's only worth adding **once we actually measure the room.**

**Costs that make "not yet" the right call right now:**

- Adds a second daemon + ALSA plugin into a path we're keeping minimal **while the I²S
  clock wedge is unresolved**.
- `alsa_cdsp` **restarts the pipeline on rate/format change → a device reconfigure**, which
  is the _class_ of event that triggers the wedge. Adding a new trigger surface is exactly
  wrong until the wedge is settled.
- Forfeits bit-perfect (fine on lossy 320k Spotify, but you get nothing for it here).

## The trigger to revisit

Do this upgrade when **both** are true: (a) the I²S wedge is resolved or reliably
mitigated (see the runbook), and (b) we have a room measurement in hand. (a) is the hard
gate — don't add DSP to a wedgy path.

## The recipe when we do it (fully open source, no proprietary lock-in)

**Measure (the one-time step — Android reality):**

- Phone is **Android**, so the built-in mic is untrustworthy and there's no iOS-Housecurve
  equivalent. Buy a calibrated USB-C mic: **Dayton iMM-6C** (the USB-C model — NOT the
  3.5mm iMM-6, which is unreliable on Android). ~€30–45; Amazon.es / Thomann.es /
  SoundImports ship to Barcelona.
- Whether the _Android phone_ will use it as an input is hit-or-miss; the **guaranteed path
  is iMM-6C → laptop → REW** (free, but note: REW is closed freeware). For a fully-FOSS
  capture, do a log-sweep with `sox`/`arecord` and feed the impulse response to DRC-FIR.
- Measure **at the listening seat**, speakers/furniture in normal positions.

**Generate the filter (FOSS, self-tuning / "automatic"):**

- **DecayCore** (github.com/VilhoValittu/DecayCore) — auto-optimizes target, phase-aware,
  exports WAV FIR **directly for CamillaDSP**. Cleanest modern match.
- or **DRC-FIR** (drc-fir.sourceforge.net) — classic GPL, self-tuning, command-line.

**Convolve:** CamillaDSP (GPL, the engine) via the `alsa_cdsp` ALSA plugin. BruteFIR is the
FOSS alternative convolver.

## "Adaptive" — checked, and not needed here

Continuous/real-time correction that follows the listener (Sonos Trueplay, Dirac Live,
Audyssey, Anthem ARC) is **all proprietary — no mature FOSS equivalent** — and it solves a
problem a **fixed listening chair doesn't have**. Room correction is a **one-time static
filter** for a fixed speaker+room+seat; the mic is a tool used once, not left plugged in,
and nothing adapts live. Re-measure only if the speakers/room change.

Poor-man's positional adaptivity that _is_ FOSS: CamillaDSP supports runtime config
switching (websocket API / camilladsp_zmq), so we could script "couch" vs "desk" filter
profiles and switch on demand. Covers the realistic two-spots case without any proprietary
system. See the automated variant below.

## Tier 3 (further-future): automate the profile switch by tracking a phone

Extends the manual runtime-switch above — instead of picking "couch"/"desk" by hand, detect
which listening zone the phone is in and load the matching CamillaDSP profile automatically.
All FOSS, and it slots onto existing fleet infra (rk1a already runs Home Assistant).

**Mechanism:** phone presence → Home Assistant → CamillaDSP websocket (`SetConfigName` /
reload). Stand up [ESPresense](https://espresense.com/) nodes (ESP32, a few € each) as HA
room sensors; an HA automation calls the CamillaDSP websocket to load `couch.yml` vs
`desk.yml` on a debounced zone change.

**Granularity is the whole story — and it works out in our favour:**

- Cheap indoor tracking (BLE / ESPresense) resolves **zone level (~1–3 m)**, NOT seat level.
  Wi-Fi RSSI (5–15 m) is useless; only UWB anchors + a UWB phone (Pixel/Samsung) give seat
  precision (~10–30 cm), and that's overkill with fragmented Android UWB APIs.
- Zone-level is the _correct_ resolution, not a compromise: room correction is dominated by
  **bass room modes** that shift over ~0.5 m, so correction IS position-sensitive — but the
  couch (far-field) and desk (near-field) profiles differ by far more than the tracking
  error, so zone-switching lands the right ballpark filter every time. And **you don't move
  while listening** — the job is "I got up and moved to the couch, load that filter," which
  zone presence answers exactly. Seat-follow ("optimize continuously as I walk around") is the
  proprietary Trueplay/Dirac fantasy that a person in a chair doesn't need.

**Wedge-safe:** a CamillaDSP filter reload swaps FIR coefficients WITHOUT reopening the ALSA
device as long as rate/format are unchanged (always 44.1k here). So profile-switching does
NOT hit the device-reconfigure event that triggers the I²S wedge — unlike the `alsa_cdsp`
rate-change restart flagged above, this is on the safe side of that line.

**Caveats:** whose phone wins with multiple people; phone-in-pocket-across-the-room ≠
ears-at-the-seat (debounce: only switch after settled in a zone N seconds). Still gated behind
the same prerequisites as any DSP work — wedge resolved AND a measurement in hand — plus a
third: you must measure **each zone separately** (N profiles = N mic sweeps) and stand up
ESPresense + an HA automation. A tier-3 extension that only lights up after room correction
itself exists.

## What's already in place (the non-DSP wins we DID take)

From the same moOde study — the only "audio tuning" with a real mechanism — deployed
2026-07-06 in `modules/nixos/profiles/pi/hifi.nix`: `performance` CPU governor + spotifyd
`SCHED_FIFO` (priority 5). XRUN insurance, not a wedge fix.
