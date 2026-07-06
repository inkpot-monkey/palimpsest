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
> and skip `provision`. The image attribute is `config.system.build.sdImage` (`images.sd-card`
> does not exist on the pinned toolchain).

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

## Toolchain pin (why `nixos-raspberrypi` is pinned, and the forward path)

`flake.nix` pins `nixos-raspberrypi` to **`6b30596`** (Feb 2026). **Do not bump it without
re-validating a porcupineFish boot.** Newer revs (e.g. `06c6e351`, May 2026) switched the RPi
vendor kernel from the **stable** branch (`linux_rpi-bcm2711-6.12.34-stable`) to **unstable/next**
(`6.12.87-unstable`), which **hangs porcupineFish in the initrd before systemd ever starts**.

### How to recognise this failure (it's deceptive)

- Monitor stays black the whole time (see above — that's normal here, not the bug).
- Never joins wifi/tailscale.
- Mount the flashed card and check the root partition: **`/var` is empty** and the **root fs was
  never grown** past the image's ~5.8 GB (it auto-grows via `x-systemd.growfs` on first boot).
  Both ⇒ it died in stage-1/initrd, *before* activation. (A late failure like sops would still
  boot, populate `/var`, and grow the root.)

### Forward path (don't stay on Feb 2026 forever)

The current `nixos-raspberrypi` still ships the good kernel alongside the broken default
(`pkgs/linux-rpi/kernels.nix` lists `v6_12_34` … `v6_12_87`). So you can move to a *newer*
`nixos-raspberrypi` (newer u-boot/firmware/fixes) and just `lib.mkForce`
`boot.kernelPackages` back to the `v6_12_34` variant — `raspberry-pi-4.nix` only sets it with
`lib.mkDefault`. Validate with one reflash (ideally once the rk1 native builders are available —
see `modules/nixos/profiles/pi-builder.nix`), then report the initrd regression upstream to
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

## Why this host is pinned to nixpkgs / home-manager 25.11 (and paths to 26.11)

The rest of the fleet tracks **nixpkgs-unstable (26.11)**, but porcupineFish (and any
`mkPiSystem` host) is built by **`nvmd/nixos-raspberrypi`**, which hard-pins
`nixpkgs = github:NixOS/nixpkgs/nixos-25.11` on *every* branch (`main`, `develop`). That pin is
deliberate: the flake's Pi vendor kernel, firmware/`config.txt` handling, and the **HiFiBerry DAC2
ADC Pro** device-tree overlay are curated against 25.11 (see `audio_blog.md`). Because of this,
the host's home-manager input is `home-manager-25_11` (release-25.11) — home-manager evaluates
against the *system* nixpkgs, and the unstable home-manager hard-requires nixpkgs' newer
`lib/services` ("modular services") library, which does **not** exist in 25.11.

Consequence for shared home profiles: any home module that uses an **unstable-only** home-manager
option (e.g. `programs.ssh.settings`, `programs.git.settings`, `xdg.userDirs.setSessionVariables`,
`home.stateVersion = "26.11"`) will fail to *evaluate* here — and `lib.mkIf`/profile-disable does
**not** suppress "option does not exist" errors (unknown-option checks run during structural
name-collection, before the condition). The repo handles this two ways:

- **De-monolith:** `users/inkpotmonkey/home/profiles.nix` imports the desktop/dev modules
  (`gui`/`dev`/`ai`/`emacs`) **only on gui hosts** (branching on
  `osConfig.custom.users.inkpotmonkey.identity.profile`), so headless/cli hosts never import them.
- **Version-guard cli-core:** modules imported on every host (`ssh.nix`, `git.nix`, `base.nix`)
  pick the API/value the running home-manager actually provides (`options.programs.X ? settings`,
  `lib.versionAtLeast lib.version "26.05"`).

### Paths to 26.11 (when/if you want to unify the Pi onto unstable)

Ranked by risk (researched 2026-06; archive dates current as of then):

1. **Wait for `nvmd/nixos-raspberrypi` to track the next stable (26.x), then bump** the
   `nixos-raspberrypi` + `home-manager-25_11` inputs. *Lowest risk* — keeps the vendor kernel and
   curated HiFiBerry overlay; the version-guards above degrade to no-ops. Recommended default.
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
