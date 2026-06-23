# Runbook & Post-mortem: porcupineFish audio goes silent ("puff, then nothing")

**Status:** Known, recurring. Root cause is an SoC-level I²S/clock wedge, **not** a
config or hardware fault. **Incident documented: 2026-06-22.**

---

## TL;DR — if the speakers are silent

**Symptom:** Spotify/`spotifyd` says it's playing, you hear a brief *puff* of noise
when playback starts, then silence. No sound from any source.

**Recovery (do this first):**

> ### ⚡ COLD power-cycle the Pi. Unplug the power, wait ~30 s, plug back in.
> A `reboot` / `systemctl reboot` / redeploy **will not fix it.** Only cutting power does.

**Do NOT, while diagnosing:**
- ❌ Run `speaker-test` / play a test tone "to check" — **opening the audio device
  re-triggers the wedge**, so each test puts you back to square one and needs another
  cold boot. (This is how the 2026-06-22 investigation kept "un-fixing" itself.)
- ❌ Trust a warm `reboot`, a `nixos-rebuild switch`, or a generation rollback to fix
  it — none of them touch the wedged silicon.
- ❌ Reflash the SD card (the historical "fix"). Reflashing only helped because it
  forces a **power-off**; the cold power-cycle above is the same fix in 30 seconds and
  loses no state.

---

## Signal chain / hardware inventory

`spotifyd` → **HiFiBerry DAC2 ADC Pro** (PCM512x DAC + PCM186x ADC) → analog out →
**amplifier** → **Titus EZ passive bookshelf speakers**.

> **Does "Titus EZ" matter to this bug? No.** They're **passive** loudspeakers (no
> electronics of their own) sitting at the very end of the chain, downstream of the amp.
> The wedge is a *digital I²S clock* failure upstream of the DAC's analog output — the
> bits never get clocked out, so nothing reaches the amp or speakers regardless of which
> speakers are connected. The speaker model is recorded here only for inventory; it has
> no bearing on the silence. (They do, of course, need a working amplifier — the amp is in
> the ruled-out table below.)

## What it is NOT (ruled out with evidence on 2026-06-22)

| Hypothesis | Verdict | Evidence |
|---|---|---|
| spotifyd config (`control`/`mixer`/`volume_controller`) | ❌ not the cause | Tones sent **directly** to the DAC (`speaker-test`, spotifyd stopped) are also silent. |
| Kernel changed | ❌ not the cause | `gen14` (last-good) and `gen19` kernel are the **same store path** `h0bp…-linux_rpi-bcm2711-6.12.47`. The "had to recompile the kernel" was the cached-`out` / uncached-`dev`+`modules` multi-output gotcha — same binary. |
| Overlay / `config.txt` (`dtparam=slave`) | ❌ not the cause | `config.txt` is **byte-identical** between generations. (Aside: `slave` **is required** — master mode won't open the PCM at all: `-EINVAL` at every rate.) |
| ALSA mixer muted / persisted bad state | ❌ not the cause | All controls open: `Digital` on @ ~90 %, `Analogue` 0 dB, auto-mute off. `/var/lib/alsa/asound.state` saves everything **open**. |
| DAC chip muted / standby / clock error | ❌ not the cause | PCM512x I²C registers during playback: `reg0x02=0x00` (active), `reg0x03=0x00` (unmuted). Status regs **identical** wedged vs working. |
| Amp / speakers / cabling (hardware) | ❌ not the cause | A cold boot restores sound with no physical changes; the user has reproduced + cleared this repeatedly by power-cycling. |

## Root cause (well-supported inference)

The Raspberry Pi 4's **I²S peripheral / clock generator** (`fe203000.i2s`, fed from
`plld` → `plld_per` → `pcm`) gets into a **wedged state** that produces no usable
bit-clock for the DAC, while every software-visible value still reads "correct".

> **Leading structural suspect (added 2026-06-23 after web research):** running this
> "**Pro**" board in **I²S slave mode is itself the questionable choice**, and is the
> most likely thing that puts the Pi in the failure regime. HiFiBerry designs the Pro
> boards to be I²S **master** — the dual onboard oscillators (22.5792 MHz for the 44.1 k
> family, 24.576 MHz for 48 k) exist precisely to clock the bus cleanly, and master is
> the documented default. HiFiBerry explicitly warn that **slave mode hands clocking back
> to the Pi, "which has more jitter,"** and position `,slave` as a niche / Pi-5 workaround.
> In slave mode the Pi must *synthesise* the I²S clock with a fractional/MASH divider —
> exactly the regime where Pi clock glitches and wedges cluster.
> ([HiFiBerry: master-vs-slave clocking](https://www.hifiberry.com/blog/techtalk-choose-the-right-clocking-for-your-mpx-setup/),
> [driver changes](https://www.hifiberry.com/blog/changes-in-hifiberry-drivers/))
>
> **Caveat — why slave was chosen here, and why "just flip to master" isn't a free win:**
> we *observed* master mode failing on this board — the PCM refused to open, `-EINVAL` at
> every rate. The likely reason is that this is the **ADC Pro** (dual codec: PCM512x DAC +
> PCM186x ADC), and getting both codecs onto one master clock domain is fiddly; nobody has
> confirmed the `hifiberry-dacplusadcpro` overlay runs both cleanly in master. So master
> mode is the *principled* fix but needs hands-on bring-up, not a one-line flip.

- The HiFiBerry DAC2 ADC Pro runs in **I²S slave mode** (`dtparam=slave`), so the DAC
  is entirely dependent on the Pi's bit-clock. If the Pi's I²S clock is wedged, the DAC
  faithfully converts… nothing. It does not flag an error (its clock-loss detector is
  coarse), which is why `reg0x03`/auto-mute look healthy.
- The wedge is **invisible to all software state we can read**: PCM512x I²C registers,
  `/sys/kernel/debug/clk/clk_summary` (frequencies identical: `pcm`=1.536 MHz for 48 k),
  and `dmesg` (no I²S/clock/xrun messages). Confirmed 2026-06-22.
- It **survives a warm reset** (the I²S block / PLL is not re-initialised without a
  power-on-reset) but is cleared by a **cold power-cycle**. This is exactly why
  reflashing "fixed" it historically (reflashing power-cycles the board) and why warm
  reboots + a full generation rollback to the byte-identical last-good config did *not*.

**Trigger:** (re)configuring the I²S clock when the audio device is **opened** —
strongly suspected to be a **sample-rate switch** that reprograms the `plld_per`
divider (e.g. a 48 kHz `speaker-test` when the chain was last at 44.1 kHz). Reproduced
2026-06-22: a cold boot fixed it, and the *very next* 48 kHz `speaker-test` re-wedged it
immediately. Why it broke "out of nowhere": it had been running fine on 44.1 kHz Spotify
content; the first off-rate open (or an unlucky open/close) wedged the clock, and warm
reboots couldn't recover it.

The recent `volume_controller = "alsa"` change (commit `69e84c0`, deployed 2026-06-22)
is **incidental, not causal** — it changed how spotifyd opens/drives the device but the
defect is in the SoC/kernel I²S clock handling.

## Mitigations (ranked)

1. **Operational (in place via this runbook):** recover with a **cold power-cycle**,
   never a warm reboot. Never debug with `speaker-test`.
2. **Reduce triggering — lock the sample rate** so the I²S divider never switches. The
   proximate trigger is an audio-device open at an off-rate (a 48 k open re-wedged it
   immediately, 2026-06-22). Locking to one fixed rate end-to-end (ALSA `plug`+`rate`
   wrapper PCM, since there's no PulseAudio/PipeWire) stops the switch. This is a
   **reasonable mitigation, not a proven cure** — no public report confirms a fixed rate
   cured intermittent I²S *silence* specifically.
   - ⚠️ **Which rate is not obvious.** spotifyd plays **44.1 kHz** natively (bit-perfect if
     we pin 44.1, no resampling), BUT on the **Pi-as-master** 44.1 kHz is the *fractional/
     MASH-divided, higher-jitter* family — **48 kHz is the cleaner integer-divided clock**
     on the Pi. So "lock to 44.1" keeps spotifyd bit-perfect but on the dirtier clock;
     "lock to 48" gives a cleaner clock but resamples everything. ([RPi forums: I2S clocks /
     fractional-vs-integer division](https://forums.raspberrypi.com/viewtopic.php?t=193550))
3. **Root-cause fix (better, but needs hands-on bring-up): get this Pro board onto its own
   master clock.** Per the structural suspect above, the real fix is master mode
   (`hifiberry-dacplus-pro` / drop `dtparam=slave`) so the HAT's 22.5792 MHz oscillator
   clocks 44.1 k cleanly and the rate-cleanliness tension disappears. Blocked by the
   observed `-EINVAL` (the ADC half may force slave); resolving this means working out
   master-mode operation for the dual-codec ADC-Pro overlay. **Do this at the device** (it
   re-wedges on device open, so expect cold-boot cycles).
4. **Kernel/clock fix:** research found **no specific upstream commit** for an I²S
   wedge-on-rate-switch, so there's nothing to chase here — and **no kernel bump is needed
   or available**. **Do not** bump to an unstable kernel anyway — see memory +
   `audio_blog.md` (6.12.87/6.18.x hang in initrd).

## Master-mode bring-up — the real fix (TO ATTEMPT, needs the device)

This is the root-cause fix (see "Leading structural suspect" above): get the DAC onto
its own oscillators so the Pi stops synthesising a jitter/wedge-prone clock. It is **not
yet validated** — capture results here when you run it. Confirmed groundwork (web research
2026-06-23 + on-host inspection):

- **Master is the documented default** for the single `hifiberry-dacplusadcpro` overlay —
  you select it simply by **dropping `dtparam=slave`** (there is no separate `-pro`
  overlay; `,slave` is positioned by HiFiBerry as a *Pi-5* workaround, not for a Pi 4).
- The clock-select is **codec-internal** (PCM5122 GPIO over I²C), so **no Pi-header GPIO**
  can be missing/contended — that's not the cause of the earlier `-EINVAL`.
- A per-rate **`-EINVAL` on open is a deterministic *config rejection*, NOT the wedge**
  (the wedge lets open succeed, then goes silent). So master-mode bring-up is
  **warm-reboot-iterable** — you only need a cold boot to (a) start from an un-wedged
  board and (b) recover if you accidentally open the device off-rate in slave mode.

**Procedure (at the device — expect cold-boot cycles):**

1. **Cold power-cycle first** (clear any wedge; start clean).
2. Edit `modules/nixos/profiles/pi/hifiberry.nix`: change the overlay block from
   `params = { slave.enable = true; };` to `params = { };` (drops `dtparam=slave`).
3. Deploy + reboot. Check the PCM **opens** without playing audibly first:
   `journalctl -k | grep -iE 'pcm512x|i2s|EINVAL'` and a quiet
   `aplay -D hw:sndrpihifiberry --dump-hw-params /dev/zero` (it lists params / errors
   without committing a stream). If it still `-EINVAL`s:
4. **Knob 1 — drop the redundant base I²S param.** In the same file remove
   `base-dt-params.i2s` (the `dtparam=i2s=on` line); the overlay enables I²S itself, and
   the extra base param is a known master-mode DAI-format conflict source.
5. Only once it opens cleanly: play real 44.1 kHz content via spotifyd and confirm sound.
   **If master mode works, the wedge should be gone** (the Pi is no longer the clock
   source) — at which point the rate-lock mitigation becomes unnecessary.
6. If master mode genuinely cannot be made to open after the above, fall back to slave +
   the rate-lock mitigation and record the exact `-EINVAL` (with `dmesg`) here.

## Detecting a recurrence (honest constraints)

The wedge is **not observable in software** (proven: DAC regs, clock tree, and dmesg are
all identical wedged vs working). Therefore:

- **There is no log line to grep for.** Don't expect one.
- **Robust detector = ADC loopback health-check.** The board is a DAC2 ADC **Pro** (it
  has a PCM186x ADC). Wire a short RCA loopback from the DAC output to the ADC input,
  then a timer can play a known tone, capture it via the ADC, and alert on low captured
  RMS — exported as a node-exporter textfile metric into the existing VictoriaMetrics /
  Grafana stack (see `monitoring` profile). This is the only way to confirm *actual*
  analog output.
- **Cheap proxy:** alert whenever the host has been warm-rebooted but not cold-booted
  since audio was last exercised — i.e. treat "warm reboot happened" as "audio output is
  now unverified until a cold boot".

## Timeline (2026-06-22)

- Until today the host ran **gen 14** (Jun-11 config); audio worked.
- ~15:28–16:20 the operator deployed gen 15/16 (incl. `volume_controller="alsa"`) and
  rebooted (warm). spotifyd connected → *puff, then silence*.
- Investigation churned through spotifyd config, the `slave` overlay (briefly removed →
  card wouldn't open at all), and a full rollback to gen 14 — all still silent, because
  every warm reboot/`speaker-test` kept the clock wedged (and test tones re-wedged it).
- **Cold power-cycle → sound restored.** A subsequent 48 kHz `speaker-test` re-wedged it,
  pinpointing the trigger as audio-device-open / rate-reconfiguration.

_See also: `audio_blog.md` (HiFiBerry/NixOS bring-up saga), `README.md`._
