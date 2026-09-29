# PorcupineFish - HiFiBerry Audio Node

NixOS configuration for a Raspberry Pi 4 equipped with a HiFiBerry DAC2 ADC Pro, serving as a Spotify Connect and Mopidy audio node.

> ⚠️ **Speakers silent ("puff, then nothing")?** It's an SoC I²S/clock wedge, not config
> or hardware. **Fix = COLD power-cycle the Pi** (unplug power, wait 30 s, replug); a warm
> `reboot`/redeploy/rollback will NOT fix it, and **don't** run `speaker-test` to "check"
> (it re-triggers the wedge). Full post-mortem: **[`RUNBOOK-audio-silence.md`](./RUNBOOK-audio-silence.md)**.

## Quick Specs

- **Hostname**: `porcupineFish`
- **IP**: DHCP/reserved on LAN (often `192.168.1.21`)
- **Architecture**: `aarch64-linux`
- **Audio Stack**: PipeWire + ALSA (HiFiBerry Overlay)
- **Services**: `spotifyd` (Spotify Connect), `mopidy` (Local/Web).

## Adding a second audio source — the arbitration rule (banked from moOde)

Today this host has **one** thing that opens the DAC: `spotifyd`, which grabs
`hw:sndrpihifiberry` **exclusively**. That single-source design is deliberate and is
also its most wedge-resistant property (one native rate, no rate-switching — see the
[RUNBOOK](./RUNBOOK-audio-silence.md)). **Before adding AirPlay (shairport-sync), a
local library (MPD/Mopidy), Bluetooth, etc., read this** — two clients racing for the
raw `hw:` device means the second gets `EBUSY` and silently fails.

The [moOde](https://github.com/moode-player/moode) audiophile player solved exactly this
and its pattern is the blueprint to copy:

- **One shared, non-mixing ALSA device** (`type copy` → the hardware PCM, _not_ `dmix`):
  access stays exclusive/bit-perfect, only one client holds the DAC at a time.
- **Explicit arbitration, not luck:** each source's start hook flips an "active" flag and
  **stops the others first** (moOde runs `mpc stop` before a renderer opens the device),
  with a per-source "resume on disconnect" toggle. librespot/spotifyd support this via
  `--onevent` / `on_song_change` hooks.

So the port is: a shared ALSA `type copy` PCM + a tiny arbiter (systemd + event hooks)
that pauses whoever holds the device when another source goes active. Don't reach for
`dmix` for _mixing_ — the only reason to consider a persistent `dmix` here is the
_clock-stability_ trade discussed in the RUNBOOK, which is a separate decision.

## Deployment

Deploy updates directly from your laptop (Stargazer). This command builds the system locally and pushes it to the Pi.

```bash
nixos-rebuild switch --flake .#porcupineFish --target-host root@porcupineFish --accept-flake-config
```

> Notes:
>
> - `--accept-flake-config` is required for binary caches.
> - If `porcupineFish` is not resolvable via DNS/hosts, use `root@<ip>` instead.

## Initial Setup (New SD Card)

We use the `build-pi` helper for bootstrapping and flashing. You can run it
either directly or via the flake app.

### 1. Provision (Build, Flash, & Setup)

The `provision` command automatically generates SSH identity keys, updates SOPS secrets, builds the SD image, flashes it to the SD card, and injects the new keys into the flashed image.

```bash
# WARNING: Wipes target device
nix run .#build-pi -- provision /dev/sdX porcupineFish
# or: bash ./parts/apps/build-pi/build-pi.sh provision /dev/sdX porcupineFish
```

> **SOPS re-key:** `build-pi provision` generates a fresh host key, points the host's
> `&<host>` anchor in **`secrets/.sops.yaml`** (the stash repo) at its derived age key,
> runs `sops updatekeys` over `secrets/profiles/*.yaml`, then **verifies every file the host
> references is keyed** (it enumerates `config.sops.secrets.*.sopsFile` and aborts if any is
> missing — guarding against the all-or-nothing failure below), commits+pushes the stash
> repo, and bumps the `secrets` flake input. The host must already be declared in
> `secrets/.sops.yaml` (a `&<host>` key anchor + `*<host>` in each relevant `creation_rules`);
> if not, the script tells you what to add. For an *existing* host where you'd rather keep its
> current key (no re-key), use the manual flow in [Secrets (SOPS)](#secrets-sops--all-or-nothing)
> and skip `provision`. The image attribute is `config.system.build.sdImage`, which is what
> `build-pi.sh` uses. (Since the 2026-09-29 pin bump `config.system.build.images.sd-card` also
> exists, but it evaluates to a *different* derivation — don't mix them.)

## How `build-pi` Chooses Defaults

If you omit `config_name` or `device`, `build-pi` shows interactive menus
ordered from most likely to least likely:

1. **Host targets** (`provision`):

   - Tries to include only flake hosts that expose `config.system.build.images.sd-card`
   - Falls back to hosts found under `hosts/*/configuration.nix` if evaluation fails
   - `porcupineFish` first (default)
   - Pi-like names next (e.g. names containing `pi`, `rpi`, `porcupine`)
   - Remaining hosts alphabetically

1. **Flash devices** (`provision`):

   - Writable block devices from `lsblk`
   - `/dev/mmcblk*` first (very likely SD slot)
   - Removable/USB disks next
   - Internal disks (e.g. NVMe) last

You can inspect menus without changing anything:

```bash
nix run .#build-pi -- targets
nix run .#build-pi -- devices
```

### 2. Boot

Insert card and power on. The Pi checks into WiFi automatically using secrets managed by SOPS.
There is **no console on HDMI** during boot (`config.txt` sets `disable_fw_kms_setup=1`, so the
framebuffer only comes up once the `vc4` KMS driver loads late in boot) and `headless.nix`
disables the tty1/serial gettys. The only early console is **serial UART** (`enable_uart=1` is
set; wire a USB-UART to GPIO pins 6/8/10 @ 115200). So the real "did it boot?" signal is whether
it appears on **tailscale**, not the monitor.

## Toolchain pin (why `nixos-raspberrypi` is pinned, and how to bump it)

`flake.nix` pins `nixos-raspberrypi` to **`24c74e7`** (`develop`, 27 Sep 2026). Since 2026-09-29
the kernel and the userspace are **separate** decisions, so read them separately:

**Kernel — never the input's default.** This rev's default is
`linux_rpi-bcm2711-6.18.52-unstable_20260915`, and unstable/next-branch kernels hang this host in
the initrd before systemd ever starts. `configuration.nix` therefore pins
`boot.kernelPackages = lib.mkForce pkgs.linuxAndFirmware.v6_18_39.linuxPackages_rpi4`
— `linux_rpi-bcm2711-6.18.39-stable_20260724`, the newest **stable**-tagged bundle this rev
offers, and a real 6.12→6.18 LTS jump from the previous `6.12.47-stable` pin.
**Do not bump either without re-validating a boot at the device.**

> **Read the `tag`, not the version number.** Stability is not a property of the version: `6.18.34`
> is `stable_20260609` on `develop` but `unstable_20260604` on `main`. The authority is
> `pkgs/linux-rpi/linux-sources.nix` in the pinned rev, and the resolved name carries it —
> `nix eval --raw .#nixosConfigurations.porcupineFish.config.boot.kernelPackages.kernel.name`
> must end in `-stable_YYYYMMDD`. Only `stable_*` kernels have ever booted here.

> **A non-default bundle is not on `nixos-raspberrypi.cachix.org`** (that cache carries the
> default's `out` only). Both this kernel and its `dev`/`modules` outputs build from source on the
> rk1b aarch64 builder — native, not QEMU, so tens of minutes rather than hours. Run
> `just cache-kernel porcupineFish` afterwards to push all three to `palebluebytes.cachix.org`, or
> the next deploy after a GC recompiles the lot.

**Userspace — nixpkgs 26.05**, up from 25.11. `nixos-raspberrypi` hard-pins its own nixpkgs, so
every *program* on this host comes from that release, still one behind the rest of the fleet
(nixos-unstable / 26.11). Taking this bump was the README's own recommended forward path (option 1
under "Paths to unstable"): the home-manager input moved with it to `release-26.05` and was renamed
`home-manager-pi`, so the version-guards in `users/inkpotmonkey/home/*` now take their
`versionAtLeast "26.05"` branches. It also retired a `sops.package` override this host carried:
26.05's default `go` **is** `go_1_26`, which is what sops-nix HEAD needs.

### How to recognise this failure (it's deceptive)

- Monitor stays black the whole time (see above — that's normal here, not the bug).
- Never joins wifi/tailscale.
- Mount the flashed card and check the root partition: **`/var` is empty** and the **root fs was
  never grown** past the image's ~5.8 GB (it auto-grows via `x-systemd.growfs` on first boot).
  Both ⇒ it died in stage-1/initrd, *before* activation. (A late failure like sops would still
  boot, populate `/var`, and grow the root.)

### Bumping the pin again

The vendor kernel tracks **LTS** (it moved 6.12→6.18 upstream in mid-2026), so it lags mainline by
~2–3 release cycles by design — that's fine. Pure *mainline* is **not** an option: the HiFiBerry
machine driver + the `hifiberry-dacplusadcpro` overlay are **vendor-only** (the PCM512x/PCM186x
codec drivers are upstreamed; the glue that binds them to the Pi's I²S is not), so stay on the
vendor kernel.

The recipe, which is what the 2026-09-29 bump followed:

1. Read `pkgs/linux-rpi/linux-sources.nix` in the candidate rev and pick the newest entry whose
   `tag` starts with `stable_` — **not** the newest `modDirVersion`, and **not**
   `linuxAndFirmware.default`/`.latest`, both of which point at `unstable_*` snapshots.
1. Pin the rev in `flake.nix` and `lib.mkForce` that bundle in `configuration.nix`.
   `raspberry-pi-4.nix` sets `boot.kernelPackages` with `lib.mkDefault`, so the force wins.
1. Check whether the rev's `flake.nix` moved its `nixpkgs` pin. If it did, move
   `home-manager-pi` to the matching `release-XX.XX` in lockstep — home-manager evaluates against
   the *system* nixpkgs, and a mismatched pair fails to evaluate.
1. `nix eval --raw …boot.kernelPackages.kernel.name` and confirm it ends `-stable_YYYYMMDD`.
1. Build (`nixos-rebuild --build-host rk1b … build`) and `just cache-kernel porcupineFish`.

**Then validate at the device.** A bad kernel hangs in initrd, with no HDMI console and no
network, and extlinux does **not** auto-fall-back. So this is an at-the-device change, **not** a
remote `switch` + reboot.

> That caution is sharper here than it reads. The documented fix for the audio wedge is a **cold
> power-cycle** ([`RUNBOOK-audio-silence.md`](./RUNBOOK-audio-silence.md)) — so a `switch` that
> writes an unvalidated extlinux entry arms a brick that the *other* runbook will spring. Once
> switched, the next boot from any cause is the test, whether or not you meant it to be.

### The recovery path is the boot menu, not a reflash

"No auto-fall-back" is true but incomplete, and the difference decides how you should do this.
u-boot reads `/boot/extlinux/extlinux.conf`, which carries `MENU TITLE` and **`TIMEOUT 50`** — 5
seconds (syslinux counts in tenths) of interactive menu *before* Linux is entered at all. A kernel
that hangs in initrd therefore cannot stop you reaching it: u-boot has already handed over or not.
Every past generation is still listed, and checked on 2026-09-29 all of them pointed at the same
retained `…-6.12.47-stable_20250916-Image`, present in `/boot/nixos/`. `/boot` is the 117G
partition at 12% use, so a second kernel costs nothing.

So the cheap, reversible validation is:

1. **Attach serial UART first** (GPIO 6/8/10 @ 115200). Without it there is no menu and no
   recovery — this is the one non-negotiable step.
1. `just deployBoot porcupineFish` — stages the generation as default for next boot *without*
   activating it, so a failure costs a reboot rather than a running system.
1. Reboot at the device and watch the serial console.
1. If it hangs: power-cycle, catch the 5-second menu, select the previous `nixos-NN-default`
   entry. You are back on 6.12.47 without touching the card.

**Prefer this to a reflash.** Reflashing regenerates the SSH host key, which invalidates the sops
age key derived from it — so a "safe" reflash actually costs you `sops-install-secrets`
(all-or-nothing: even the wifi PSK never lands, and the Pi silently fails to join the network)
unless you restore `/etc/ssh/ssh_host_ed25519_key{,.pub}` or re-key. Keep a flashed card as the
*last* resort, not the first.

> Caveat on the above: the menu behaviour is read off the generated `extlinux.conf` plus u-boot's
> documented `sysboot`/pxe menu support — it has not been exercised on this board. Confirm the
> menu actually renders on serial **before** you rely on it, i.e. reboot once with serial attached
> while still on the known-good kernel.

See `UPGRADE-audio-dsp.md`'s sibling reasoning; report any initrd regression upstream to
`nvmd/nixos-raspberrypi`.

## Secrets (SOPS) — all-or-nothing

`sops-install-secrets` is **all-or-nothing**: the host's age key (derived from
`/etc/ssh/ssh_host_ed25519_key`) must be a recipient of **every** sops file the host references,
or the service aborts and installs **none** of them — so even a correctly-keyed wifi PSK never
lands and the Pi silently fails to join the network. porcupineFish references **six** files in the
`secrets/` stash repo: `github.yaml`, `wireless.yaml`, `restic.yaml`, `networking.yaml`,
`media.yaml`, `garnix.yaml`.

**Re-key all six (manual, until `build-pi` is fixed):**

```bash
# porcupineFish's age key (from its preserved host key):
#   age1aq4fp9qrhz03vqrzj8gjw4xm2dgkueudflzex8vmmrg8efe0rswqcv8jah
cd secrets
# Ensure &porcupineFish is in each file's creation_rule in .sops.yaml, then:
for f in github wireless restic networking media garnix; do sops updatekeys -y profiles/$f.yaml; done
git commit -am "re-key porcupineFish" && git push
cd .. && nix flake update secrets    # bump the input so the build sees it
```

Audit which files a host needs vs which are keyed:
`nix eval .#nixosConfigurations.porcupineFish.config.sops.secrets --apply 's: map (v: v.sopsFile) (builtins.attrValues s)'`,
then grep each for the age key.

## Reflash & restore the host key

Reflashing regenerates the SSH host key, which changes the derived age key and breaks SOPS
decryption. **Preserve the existing key** so the (already-keyed) secrets stay valid:

```bash
# BEFORE flashing — capture from the old card's root partition:
mkdir -p ~/porcupineFish-hostkey && cp -a /mnt/oldroot/etc/ssh/ssh_host_ed25519_key{,.pub} ~/porcupineFish-hostkey/
# AFTER flashing — restore onto the new root (partition 2), root:root, 0600/0644:
sudo mount /dev/sdX2 /mnt/new && sudo install -d -m0755 /mnt/new/etc/ssh
sudo install -o root -g root -m0600 ~/porcupineFish-hostkey/ssh_host_ed25519_key     /mnt/new/etc/ssh/
sudo install -o root -g root -m0644 ~/porcupineFish-hostkey/ssh_host_ed25519_key.pub /mnt/new/etc/ssh/
sudo sync && sudo umount /mnt/new
```

Verify the key derives to the expected identity:
`ssh-to-age < ~/porcupineFish-hostkey/ssh_host_ed25519_key.pub` ⇒ `age1aq4fp9…`.

## Alternative: Native Build (On Pi)

If local emulation is too slow, you can build natively on the Pi.

1. **Sync Source**:

   ```bash
   rsync -avz --delete --exclude='.git' ~/code/nixos/ root@porcupineFish:~/nixos-config/
   ```

1. **Build on Pi (tmux recommended)**:

   ```bash
   ssh root@porcupineFish
   tmux new -s update
   nixos-rebuild switch --flake ~/nixos-config#porcupineFish
   ```

## Why this host trails the fleet on nixpkgs / home-manager (and paths to unstable)

The rest of the fleet tracks **nixpkgs-unstable (26.11)**, but porcupineFish (and any
`mkPiSystem` host) is built by **`nvmd/nixos-raspberrypi`**, which hard-pins its own `nixpkgs` on
*every* branch — **`nixos-26.05`** as of the `24c74e7` pin, `nixos-25.11` before it. That pin is
deliberate: the flake's Pi vendor kernel, firmware/`config.txt` handling, and the **HiFiBerry DAC2
ADC Pro** device-tree overlay are curated against it (see `audio_blog.md`). Because of this, the
host's home-manager input is **`home-manager-pi`** (`release-26.05`, matched to that pin) —
home-manager evaluates against the *system* nixpkgs, and a newer home-manager hard-requires
nixpkgs' `lib/services` ("modular services") library. **The two move in lockstep or not at all.**

Consequence for shared home profiles: any home module that uses an option newer than the Pi's
home-manager (historically `programs.ssh.settings`, `programs.git.settings`,
`xdg.userDirs.setSessionVariables`, `home.stateVersion = "26.11"`) fails to *evaluate* here — and
`lib.mkIf`/profile-disable does **not** suppress "option does not exist" errors (unknown-option
checks run during structural name-collection, before the condition). The repo handles this two
ways:

- **De-monolith:** `users/inkpotmonkey/home/profiles.nix` imports the desktop/dev modules
  (`gui`/`dev`/`ai`/`emacs`) **only on gui hosts** (branching on
  `osConfig.custom.users.inkpotmonkey.identity.profile`), so headless/cli hosts never import them.
- **Version-guard cli-core:** modules imported on every host (`ssh.nix`, `git.nix`, `base.nix`)
  pick the API/value the running home-manager actually provides (`options.programs.X ? settings`,
  `lib.versionAtLeast lib.version "26.05"`).

Both stay: the gap narrowed from two releases to one on 2026-09-29, it did not close, and the
guards are what make the *next* bump a lock change rather than an excavation.

### Paths to unstable (when/if you want to unify the Pi onto 26.11)

Ranked by risk (researched 2026-06, re-checked 2026-09):

1. **Follow `nvmd/nixos-raspberrypi` as it tracks each new stable, and bump in lockstep** — the
   `nixos-raspberrypi` + `home-manager-pi` inputs together, per "Bumping the pin again" above.
   *Lowest risk;* keeps the vendor kernel and curated HiFiBerry overlay, and the version-guards
   degrade as the gap closes. **This is the path taken on 2026-09-29** (25.11 → 26.05) and remains
   the recommended default. Note it converges *toward* unstable without ever reaching it.
1. **Switch toolchain to `nixos-hardware` (`raspberry-pi/4`) + the upstream generic aarch64 SD
   image**, which follows your own nixpkgs (tracks unstable cleanly). *This is the only live
   unstable-tracking option* — `nix-community/raspberry-pi-nix` (archived 2025-03-23) and the
   `Ramblurr` fork (archived 2025-05-15) are dead. **Decisive caveat:** that path defaults to the
   *mainline* kernel, where HiFiBerry drivers/overlays are **absent** (they ship in the RPi vendor
   kernel); you'd have to source the DAC2 ADC Pro `.dtbo` from the RPi firmware tree, apply it via
   `hardware.deviceTree.overlays` + `hardware.raspberry-pi."4".apply-overlays-dtmerge`, and
   confirm the `snd-soc` codec loads on mainline. Also a boot/firmware model change
   (`config.txt` → deviceTree/extlinux) and intermittent unstable breakages. **Verify the DAC2 ADC
   Pro on mainline on real hardware before committing.**
1. **Force `inputs.nixos-raspberrypi.inputs.nixpkgs.follows = "nixpkgs"`** (26.11). *Not
   recommended* — unsupported by the flake (a real-world override was found to be non-working) and
   risks the vendor kernel/firmware/overlay the flake exists to curate.

Whatever the path, reflashing regenerates the SSH host key, which invalidates the sops age key
derived from it — persist or restore `/etc/ssh/ssh_host_ed25519_key{,.pub}` (or re-key the
secrets) so `sops-install-secrets` can still decrypt.
