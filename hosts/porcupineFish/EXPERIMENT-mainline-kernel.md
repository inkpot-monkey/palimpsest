# Scope: escaping the vendor-kernel pin (mainline kernel + unstable userspace)

**Status (2026-07-07): SCOPED, NOT DONE — recommended NOT to do on porcupineFish.**
Banked so this doesn't need re-researching. This is the "could we run a mainline kernel +
fleet-current nixpkgs-unstable, forward-porting the HiFiBerry drivers ourselves?" question.
Verdict: feasible, mostly config plumbing, but the only version that preserves porcupineFish's
actual audio behaviour is an expensive, fragile out-of-tree C-driver commitment. **The scope
validates the vendor-kernel pin.** Treat as a spare-SD curiosity, never a porcupineFish change.
See sibling reasoning in [`README.md`](./README.md) (toolchain pin) and
[`RUNBOOK-audio-silence.md`](./RUNBOOK-audio-silence.md).

## Why the drivers being open source doesn't help much

The HiFiBerry drivers ARE open source (GPLv2, in the public `raspberrypi/linux` tree). The blocker
is that they're **downstream, not upstreamed** to mainline Linux. The PCM512x DAC + PCM186x ADC
*codec* drivers are already in mainline; what's vendor-only is the glue (machine driver + clock
driver + a codec gpiochip patch) and the RPi *dtoverlay* mechanism itself.

## The critical catch: the cheap path defeats master-clock mode

porcupineFish runs `params = {}` (I²S **master mode**) so the HAT's dual oscillators
(22.5792 MHz / 24.576 MHz) clock the bus — the whole point of the Pro board (and the wedge saga).
Mainline has **no driver that models "pick oscillator by sample-rate"** (vendor-only clk driver).
The config-only `simple-audio-card` prior art uses **the Pi as clock-master** — i.e. it reverts to
Pi-synthesised clocking, the exact jittery regime master mode exists to escape. So the easy path is
a clocking *regression*, not equivalent hardware behaviour.

- **porcupineFish-specific escape hatch (UNVERIFIED):** we only ever play **44.1 kHz** (spotifyd).
  So codec-as-master pinned to just the 44.1k oscillator could give clean HAT-master clocking
  *without* the per-rate switching driver — you never switch families. Statically enabling the
  right oscillator GPIO without the vendor clk driver is the unproven part. This is the only Tier-1
  variant worth trying.

## Two effort tiers

**Tier 1 — DAC-only audio out (`simple-audio-card` DT overlay).** Config-only, no C, hours of work.
Cost: single-clock (Pi-master jitter unless the 44.1-pin trick works), **no ADC**, doesn't
replicate the vendor machine driver. Fine for "sound comes out," a downgrade for "Pro board as
designed."

**Tier 2 — real DAC2 ADC Pro parity (dual codec + dual-oscillator master clock + ADC).** Carry
three vendor-only C pieces out-of-tree against mainline:

- `sound/soc/bcm/hifiberry_dacplusadcpro.c` (~450-line machine driver)
- `drivers/clk/clk-hifiberry-dacpro.c` (oscillator-select clk driver)
- the PCM512x **gpiochip** mechanism the clk driver needs

This is essentially Pierre-Louis Bossart's 2020 upstreaming RFC that **never merged**
(<https://lore.kernel.org/all/20200409195841.18901-3-pierre-louis.bossart@linux.intel.com/T/>),
carried as our own fork. Least prior art; the ADC path is barely trodden on mainline. A
**C-driver-maintenance commitment**, re-validated every kernel bump.

## NixOS plumbing (both tiers)

Correction: `nixos-hardware`'s `raspberry-pi/4` is **still the vendor kernel** — it only escapes the
vendor *bootloader*. Actual mainline = `sd-image-aarch64-new-kernel` /
`boot.kernelPackages = pkgs.linuxPackages_latest`.

1. **Boot chain** — drop `nixos-raspberrypi` modules + `boot.loader.raspberry-pi`; import
   `sd-image-aarch64-new-kernel`, `boot.loader.generic-extlinux-compatible.enable = true`
   (u-boot → extlinux → mainline `bcm2711-rpi-4-b.dtb`). Fix `/boot/firmware` layout.
1. **Kernel** — `boot.kernelPackages = pkgs.linuxPackages_latest`. The actual pin-escape.
1. **Wi-Fi/BT firmware** — re-wire by hand: `hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];`
   `hardware.enableRedistributableFirmware = true;` (mainline brcmfmac needs the nvram/clm_blob).
1. **Rewrite `modules/nixos/profiles/pi/default.nix` + `pi/hifiberry.nix`** — both are written
   entirely against nixos-raspberrypi's `hardware.raspberry-pi.config` DSL, which **vanishes**.
   Re-express every `config.txt` semantic (`dtparam=i2s=on`, `audio=off`, `force_eeprom_read`) as DT
   fragments + `boot.kernelModules`/`blacklistedKernelModules` (`snd-soc-pcm512x-i2c`,
   `snd-soc-pcm186x-i2c`, `snd-soc-simple-card`, `snd-soc-bcm2835-i2s`; blacklist `snd_bcm2835`).
1. **The DT overlay** (the real deliverable) — via `hardware.deviceTree.overlays` (`dtsText`),
   merged at build time. Try `fdtoverlay` first; fall back to nixos-hardware's
   `apply-overlays-dtmerge` only on `FDT_ERR_NOTFOUND`.

Out-of-tree module idiom (Tier 2), auto-rebuilds against the current kernel:
`boot.extraModulePackages = [ (config.boot.kernelPackages.callPackage ./my-dac.nix {}) ];`
The plumbing is easy; source-compat against ASoC internal-API churn is the recurring pain.

## The ongoing tax (the real cost)

Tracking unstable → `linuxPackages_latest` bumps often → **frequent uncached aarch64 kernel
rebuilds** (offload to rk1b/piBuilder) + overlay-binding drift (nixos-hardware has a trail of
"overlay broke on kernel bump" issues). Hand-written DT overlay = low churn. Carried C driver
(Tier 2) = high churn — the maintenance role you'd be signing up for.

## Effort verdict

- **Tier 1:** ~a weekend on a spare SD for sound; only the 44.1-pinned-oscillator variant is worth
  trying, and it's unverified. Even if it works: no ADC, and nothing porcupineFish needs.
- **Tier 2:** multi-week bring-up **plus a permanent out-of-tree ASoC maintainer role**. A hobby
  project, not a reliability improvement.

**Recommendation:** stay pinned. The only thing that would cleanly retire this whole question is the
HiFiBerry drivers being **upstreamed** to mainline — not on the horizon as of 2026, and the one
lever we can't pull without doing the upstreaming work ourselves.

### Key source references

- Vendor machine/clk drivers: `raspberrypi/linux` `sound/soc/bcm/hifiberry_dacplusadcpro.c`,
  `drivers/clk/clk-hifiberry-dacpro.c`, `sound/soc/bcm/Kconfig`,
  `arch/arm/boot/dts/overlays/hifiberry-dacplusadcpro-overlay.dts`
- Mainline codecs present, no hifiberry object: `torvalds/linux` `sound/soc/codecs/Kconfig` vs
  `sound/soc/bcm/Makefile`
- `simple-audio-card` prior art (Pi-as-master): <https://forums.raspberrypi.com/viewtopic.php?t=184543>
- NixOS mainline Pi 4: <https://wiki.nixos.org/wiki/NixOS_on_ARM/Raspberry_Pi_4>,
  `nixos/modules/installer/sd-card/sd-image-aarch64-new-kernel.nix`
- HiFiBerry on mainline (generic): <https://support.hifiberry.com/hc/en-us/community/posts/360012834757-Mainline-Linux-kernels>
- Overlay merge-tool trap: <https://github.com/NixOS/nixpkgs/issues/125354>
