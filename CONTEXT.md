# Palimpsest

A `flake-parts` NixOS configuration for a personal fleet of machines — desktops, a VPS, a Raspberry Pi audio host, and a pair of single-board LLM nodes — plus the bespoke services that run on them. This glossary fixes the language used across the repo so issues, ADRs, and commit messages stay consistent.

## Language

### Fleet & hosts

**Fleet**:
The whole set of machines this repo builds and deploys, as one unit.
_Avoid_: cluster, estate.

**Host**:
A single machine with a `nixosConfiguration`, named by a marine/animal codename (`kelpy`, `porcupineFish`, `stargazer`, …). The RK1 LLM boxes `rk1a`/`rk1b` are hosts too — "node" is just a more specific word for them, not a separate category.
_Avoid_: box, server.

**Profile**:
A toggleable feature bundle enabled through the `custom.*` namespace, composing existing modules rather than being a long-running program itself. Two kinds, structurally distinct: a **NixOS profile** is fleet-shared (under `modules/nixos/profiles/`, toggled via `custom.profiles.*`); a **home profile** is per-user (under `users/<user>/home/`, toggled via `custom.home.profiles.*`).
_Avoid_: role, preset.

**Service module**:
A bespoke long-running program packaged and wired by this repo under `modules/nixos/services/` (e.g. the bridge, the AionUi notifier). Distinct from a profile, which only toggles and configures.
_Avoid_: daemon, app.

**`custom.*`**:
The repo's own NixOS/home-manager option namespace (`custom.profiles.*`, `custom.home.profiles.*`, `custom.rk1.*`, `custom.users.*`). All first-party configuration hangs off it.

### Secrets

**Stash**:
The separate private git repository (`stash.git`) that holds all sops-encrypted secrets, consumed by this repo as the `secrets` flake input. Edits only take effect after commit + push + relock.
_Avoid_: vault, the secrets folder (it is a repo, not just a directory).

**Admin key**:
The single age recipient (`&admin`) that can decrypt every secret in the fleet and re-key the rest. It is the same key as the user's personal SSH login/signing key.
_Avoid_: master key, root key.

**Signing key**:
The dedicated, non-admin key used for commit signing (and other private-key needs) on headless or code-executing hosts, so the admin key never has to leave a trusted machine.

### Matrix bridging

**The bridge**:
The hand-written Rust `jmap-matrix-bridge` appservice that connects a JMAP mailbox (Stalwart) to Matrix. Unqualified, "the bridge" means this one.
_Avoid_: connector, gateway.

**Homeserver**:
The Matrix server the fleet runs — `tuwunel` (conduwuit lineage). Bridges register with it declaratively via its appservice directory.

**Ghost**:
A Matrix puppet user (`@_jmap_*`) the bridge creates to represent an external email correspondent inside Matrix.
_Avoid_: puppet (reserve for double-puppeting), bot, virtual user.

**Contact room / Thread room**:
The Matrix room a bridged email conversation lives in. Email rooms are scoped **per email thread**, not per correspondent.
_Avoid_: channel, chat.

**Double-puppet**:
Logging the bridge in *as the real user* (not a ghost) so the user's own Matrix account appears to send bridged messages and auto-joins rooms. Established with a one-time login token, never declaratively.

### Local LLMs

**RK1 node** (or just **node**):
Either of the pair of Turing-Pi RK1 single-board computers, `rk1a` and `rk1b` (RK3588, 32 GB). A node is also a host (see **Host**); "node" just emphasises its place in this pair. The two are currently split by role: `rk1a` is the **LLM node**, `rk1b` is the **voice node**.

**LLM node**:
`rk1a` specifically — serves local MoE models on CPU via `llama.cpp` (`custom.rk1.llm`), fronted by the `litellm` gateway on `kelpy`.
_Avoid_: GPU node, inference server.

**Voice node**:
`rk1b` specifically — runs Home Assistant plus a local Wyoming voice pipeline (faster-whisper STT + piper TTS, CPU) for the smart-home setup (`custom.rk1.homeAssistant`). It no longer serves an LLM.

**Gateway**:
The `litellm` proxy on `kelpy` that presents the local LLM nodes (and remote fallbacks) under stable backend names (`qwen-general`, `qwen-coder`).
