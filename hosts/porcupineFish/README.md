# PorcupineFish - HiFiBerry Audio Node

NixOS configuration for a Raspberry Pi 4 equipped with a HiFiBerry DAC2 ADC Pro, serving as a Spotify Connect and Mopidy audio node.

## Quick Specs
- **Hostname**: `porcupineFish`
- **IP**: DHCP/reserved on LAN (often `192.168.1.21`)
- **Architecture**: `aarch64-linux`
- **Audio Stack**: PipeWire + ALSA (HiFiBerry Overlay)
- **Services**: `spotifyd` (Spotify Connect), `mopidy` (Local/Web).

## Deployment

Deploy updates directly from your laptop (Stargazer). This command builds the system locally and pushes it to the Pi.

```bash
nixos-rebuild switch --flake .#porcupineFish --target-host root@porcupineFish --accept-flake-config
```
> Notes:
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

## How `build-pi` Chooses Defaults

If you omit `config_name` or `device`, `build-pi` shows interactive menus
ordered from most likely to least likely:

1. **Host targets** (`provision`):
   - Tries to include only flake hosts that expose `config.system.build.images.sd-card`
   - Falls back to hosts found under `hosts/*/configuration.nix` if evaluation fails
   - `porcupineFish` first (default)
   - Pi-like names next (e.g. names containing `pi`, `rpi`, `porcupine`)
   - Remaining hosts alphabetically

2. **Flash devices** (`provision`):
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

## Alternative: Native Build (On Pi)
If local emulation is too slow, you can build natively on the Pi.

1.  **Sync Source**:
    ```bash
    rsync -avz --delete --exclude='.git' ~/code/nixos/ root@porcupineFish:~/nixos-config/
    ```

2.  **Build on Pi (tmux recommended)**:
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
2. **Switch toolchain to `nixos-hardware` (`raspberry-pi/4`) + the upstream generic aarch64 SD
   image**, which follows your own nixpkgs (tracks unstable cleanly). *This is the only live
   unstable-tracking option* — `nix-community/raspberry-pi-nix` (archived 2025-03-23) and the
   `Ramblurr` fork (archived 2025-05-15) are dead. **Decisive caveat:** that path defaults to the
   *mainline* kernel, where HiFiBerry drivers/overlays are **absent** (they ship in the RPi vendor
   kernel); you'd have to source the DAC2 ADC Pro `.dtbo` from the RPi firmware tree, apply it via
   `hardware.deviceTree.overlays` + `hardware.raspberry-pi."4".apply-overlays-dtmerge`, and
   confirm the `snd-soc` codec loads on mainline. Also a boot/firmware model change
   (`config.txt` → deviceTree/extlinux) and intermittent unstable breakages. **Verify the DAC2 ADC
   Pro on mainline on real hardware before committing.**
3. **Force `inputs.nixos-raspberrypi.inputs.nixpkgs.follows = "nixpkgs"`** (26.11). *Not
   recommended* — unsupported by the flake (a real-world override was found to be non-working) and
   risks the vendor kernel/firmware/overlay the flake exists to curate.

Whatever the path, reflashing regenerates the SSH host key, which invalidates the sops age key
derived from it — persist or restore `/etc/ssh/ssh_host_ed25519_key{,.pub}` (or re-key the
secrets) so `sops-install-secrets` can still decrypt.
