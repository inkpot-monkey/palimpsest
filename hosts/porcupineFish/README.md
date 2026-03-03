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
