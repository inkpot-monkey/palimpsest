# RK1 - Turing Pi Nodes

NixOS configuration for two **Turing RK1** compute modules (Rockchip RK3588, 32 GB)
in a Turing Pi 2. Both nodes share `./common.nix`; they differ in hostname and the
profiles they enable (set in `../default.nix`).

> **Role note (ADR-0027).** These nodes used to serve a local LLM on CPU via
> `llama.cpp`. That stack was **retired** — the ~15 GB GGUF and its ~20 GB of pinned
> RAM are gone. `rk1a` is the **voice** node: Home Assistant + local Wyoming voice
> (STT/TTS), moved off `rk1b` with fresh state (it was a PoC). Voice needs no disk, so
> it fits `rk1a`'s 29 GB eMMC without an NVMe. `rk1b` is the **media + monitoring**
> node: Navidrome — the friends' shared music platform, with its library + DB on the
> NVMe `/var/cache` — plus the monitoring server and the fleet's aarch64 remote
> builder, all on its NVMe. `openclaw`, the LLM's sole consumer, is disabled and can
> return later pointed at a funded cloud model. Cloud models remain available
> fleet-wide through kelpy's LiteLLM gateway.

## Quick Specs

- **Hostnames**: `rk1a`, `rk1b`
- **Architecture**: `aarch64-linux`
- **SoC**: Rockchip RK3588 (4× A76 + 4× A55), 32 GB LPDDR, 6-TOPS NPU
- **Hardware module**: `inputs.nixos-turing-rk1` (mainline kernel, u-boot, RK1 device tree)
- **Root**: tmpfs; the eMMC (`NIXOS_SD`) holds only declared persistent state (see `common.nix`)
- **Storage**: `rk1b` carries an M.2 NVMe (`/nix` for build offload + `/var/cache` for data — see `./nvme.nix`); `rk1a` runs off the 29 GB eMMC

## 1. Flash the base OS (one-time, per node)

The RK1 boots from u-boot on the eMMC. Flashing is done over the Turing Pi BMC. Build
the GiyoMoon base image (must be built on an `aarch64-linux` machine, or with
`boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`):

```bash
nix build github:GiyoMoon/nixos-turing-rk1#nixosConfigurations.turing-rk1.config.system.build.sdImage
# image lands in ./result/sd-image/
```

Flash it to the node's eMMC via the BMC web UI (or `tpi` CLI), then power on. To run
NixOS from an NVMe instead of the eMMC, follow the "external block device" steps in the
[upstream README](https://github.com/GiyoMoon/nixos-turing-rk1#flashing-the-image-to-an-external-block-device).

Default credentials after flashing: user `nixos`, password `turing`. This account is
removed on the first switch to this config (`users.mutableUsers = false` in `common.nix`);
thereafter access is key-only SSH as `inkpotmonkey`.

## 2. First switch to this config

The nodes start as `turing-rk1` with the `nixos` user. Switch them to `rk1a` / `rk1b`.
These are `aarch64` builds — build **on the node itself** (8 cores / 32 GB handle it)
to avoid cross-compilation or `binfmt` emulation on your x86 box:

```bash
nixos-rebuild switch --flake .#rk1a \
  --target-host nixos@<node-ip> \
  --build-host  nixos@<node-ip> \
  --use-remote-sudo
```

This first switch installs your SSH keys + Tailscale (SOPS-managed) and renames the host.
Repeat for `rk1b`. After it joins the tailnet, later deploys can target the hostname:

```bash
nixos-rebuild switch --flake .#rk1b --target-host rk1b --use-remote-sudo
```

> **Alternative — build on your laptop:** add `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`
> to your workstation and drop the `--build-host` flag (slower, emulated).

## Configuration

| What | Where |
| --- | --- |
| Shared host config (hardware + profiles) | `./common.nix` |
| Per-node hostname + enabled profiles | `../default.nix` (`rk1a` / `rk1b`) |
| NVMe cache / `/nix` relocation | `./nvme.nix` (`custom.rk1.nvme`) |
| Node IPs + service ports | `parts/settings.nix` (`nodes.rk1a/rk1b`) |
| Cloud model gateway (LiteLLM, on kelpy) | `modules/nixos/profiles/litellm.nix` |

## Notes & gotchas

- **Build on the node.** These are `aarch64`; cross-building from x86 needs `binfmt`
  emulation (slow). `rk1b` is also the fleet's aarch64 remote builder
  (`modules/nixos/profiles/pi-builder.nix`), so its NVMe `/nix` has room for image builds.
- **tmpfs root.** `/` is tmpfs; only declared `environment.persistence` state survives a
  reboot. `/boot` is bind-mounted from `/persistent` so bootloader updates stick.
- **NVMe is per-node.** `./nvme.nix` is imported by both nodes but inert until
  `custom.rk1.nvme.enable = true` (currently `rk1b` only). See its header for the
  one-time disk-prep and store-migration recipe.
