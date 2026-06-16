# RK1 - Turing Pi LLM Nodes

NixOS configuration for two **Turing RK1** compute modules (Rockchip RK3588, 32 GB)
in a Turing Pi 2, each serving a local LLM over an OpenAI-compatible API via
`llama.cpp`. Both nodes share `./common.nix`; they differ only in hostname and the
model they serve (set in `../default.nix`).

## Quick Specs

- **Hostnames**: `rk1a`, `rk1b`
- **Architecture**: `aarch64-linux`
- **SoC**: Rockchip RK3588 (4× A76 + 4× A55), 32 GB LPDDR, 6-TOPS NPU
- **Hardware module**: `inputs.nixos-turing-rk1` (mainline kernel, u-boot, RK1 device tree)
- **Serving stack**: `services.llama-cpp` (CPU), port `8080`, scoped to `tailscale0`
- **Models**:
  - `rk1a` → `Qwen3.6-35B-A3B` (MoE, ~10–15 tok/s) — fast daily driver
  - `rk1b` → `Qwen3.6-27B` dense + 1.7B speculative-decoding draft (~3–4 tok/s) — best quality
- **Gateway**: registered with the kelpy LiteLLM proxy as `qwen-local` / `qwen-quality`

> **Why CPU, not the NPU?** The NPU (RKLLM runtime) genuinely *does* win at two things:
> **prefill** (compute-bound — ~130 tok/s on a ~2B model) and **small dense** models
> (1–4B at ~15–20 tok/s, at lower power). It's just the wrong tool for *this* fleet:
> - **Decode stays bandwidth-bound** even on the NPU — a small model still decodes at
>   single-digit tok/s, so the NPU doesn't break the wall we actually wait on.
> - **No MoE support** in RKLLM (as of toolkit v1.2.3, Nov 2025) → our Qwen3 `*-A3B`
>   models can't run on it at all; you'd be forced down to a dense ≤8B (8B+ is impractical).
> - **Context caps at ~16K** (often 2–4K in practice) vs our 64–128K, and it's **W8A8-only**.
> - Enabling it needs the Rockchip **vendor BSP kernel** (this module is mainline) plus
>   un-packaged proprietary runtimes — a risky migration off the maintained `nixos-turing-rk1`.
>
> The MoE on CPU is the real speed lever here. The NPU would only earn its keep as a
> *separate* tiny, always-on, low-power model (router / classifier / voice) running
> **alongside** the CPU servers — not as a replacement. Deferred, optional phase —
> see `~/.claude/plans/snuggly-growing-island.md`.

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

## 3. First start: model download

On first boot the service does two one-time, slow steps (watch them):

```bash
ssh inkpotmonkey@rk1a journalctl -u llama-cpp -f
```

1. Compiles the curl-enabled `llama-cpp` (the `modules/shared/overlays/llama-cpp.nix`
   override — nixpkgs ships `llama-cpp` without curl, which `-hf` needs).
2. Downloads the GGUF (~17–20 GB) into `/var/cache/llama-cpp` (persists across rebuilds).

## 4. Verify

```bash
# Service up + model loaded
ssh inkpotmonkey@rk1a 'systemctl status llama-cpp'
curl http://rk1a:8080/v1/models

# Quick generation
curl http://rk1a:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "default",
  "messages": [{"role": "user", "content": "Say hi in one word."}]
}'

# rk1b: confirm speculative decoding actually engaged (look for draft / accept-rate lines)
ssh inkpotmonkey@rk1b 'journalctl -u llama-cpp | grep -i draft'

# Resident weights, no swap thrash
ssh inkpotmonkey@rk1a 'free -h'

# Through the gateway (from kelpy)
curl -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://kelpy:4000/v1/models
```

## Configuration

| What | Where |
| --- | --- |
| Shared host config (hardware + profiles) | `./common.nix` |
| Per-node hostname + model | `../default.nix` (`rk1a` / `rk1b`) |
| Serving profile + tuning | `modules/nixos/profiles/local-llm.nix` (`custom.profiles.localLlm`) |
| `llama-cpp` curl rebuild | `modules/shared/overlays/llama-cpp.nix` |
| Node IPs + service port | `parts/settings.nix` (`nodes.rk1a/rk1b`, `services.private.localLlm*`) |
| Gateway entries | `modules/nixos/profiles/litellm.nix` |

### `custom.profiles.localLlm` options

| Option | Default | Description |
| --- | --- | --- |
| `model` | — | HuggingFace GGUF spec passed to `llama-server -hf` (the per-node knob). |
| `draftModel` | `null` | Optional GGUF for speculative decoding (`-hfd`); **must share the target's vocab**. |
| `port` | `8080` | Listen port (firewalled to `tailscale0`). |
| `threads` | `4` | Generation threads. On RK3588, 4 (the A76 cores) beats 8 — the A55s bottleneck. |
| `ctxSize` | `4096` | Context window. Larger = more RAM + slower. |
| `mlock` | `true` | Pin weights in RAM. Disable when RAM is contended (e.g. running a second model). |

### Changing the model

Edit the node's `model` (and optionally `draftModel`) in `../default.nix` and redeploy.
The new GGUF downloads on next service start; the old one stays cached in
`/var/cache/llama-cpp` (clear it manually to reclaim space).

## Notes & gotchas

- **HF tags**: confirm the exact `repo:quant` strings exist on HuggingFace before
  deploying — a wrong tag fails the download at service start.
- **Speculative-decode vocab**: if `llama-server` logs a tokenizer/vocab mismatch it
  silently drops the draft; remove `draftModel` to fall back to plain decoding.
- **RAM**: a 32B-class model at Q4 (~17–20 GB) + KV cache + OS fits in 32 GB with
  `ctxSize = 4096`. Raising context or running a second (e.g. NPU) model means lowering
  `mlock`/context.
- **Speed expectations**: dense 27–32B decode is ~1–1.5 tok/s on this hardware
  (bandwidth-bound); the MoE and speculative decoding are how `rk1a`/`rk1b` get past that.
