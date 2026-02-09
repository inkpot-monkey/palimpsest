# PorcupineFish - HiFiBerry Audio Node

NixOS configuration for a Raspberry Pi 4 equipped with a HiFiBerry DAC2 ADC Pro, serving as a Spotify Connect and Mopidy audio node.

## Quick Specs
- **Hostname**: `porcupineFish`
- **IP**: `192.168.1.21` (Mapped in Stargazer `/etc/hosts`)
- **Architecture**: `aarch64-linux`
- **Audio Stack**: PipeWire + ALSA (HiFiBerry Overlay)
- **Services**: `spotifyd` (Spotify Connect), `mopidy` (Local/Web).

## Standard Deployment
Deploy updates directly from your laptop (Stargazer). The system is built locally (via emulation or cross-compilation) and closures are pushed via SSH.

## Deployment

Deploy updates directly from your laptop (Stargazer). This command builds the system locally and pushes it to the Pi.

```bash
nixos-rebuild switch --flake .#porcupineFish --target-host root@porcupineFish --accept-flake-config --use-remote-sudo
```
> Note: `--accept-flake-config` is required for binary caches.

## Initial Setup (New SD Card)

We use the `scripts/deploy_pi.sh` helper for bootstrapping and flashing.

### 1. Generate Identity & Secrets
Generates SSH keys and updates `.sops.yaml` (requires `ssh-to-age`).
```bash
deploy_pi.sh bootstrap
```

### 2. Build & Flash
Builds the image and flashes it to the SD card, then injects the keys.

```bash
# WARNING: Wipes target device
deploy_pi.sh flash /dev/sdX
```

### 3. Boot
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
