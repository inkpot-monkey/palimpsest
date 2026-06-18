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

### Users & the host↔user contract

> Target architecture being designed: hosts and users split into separate repos bound by a shared contract, so any host can enable a user and on rebuild they transparently work, while hosts can deny features a user introduces. See [ADR-0015](docs/adr/0015-host-user-contract.md). Today `users/` still lives in this repo; these terms fix the language the migration aims at.

**User**:
A portable bundle of *public identity + home config + its own secrets + grantable features*, owned in its own repo. Distinct from the **system account** (`users.users.<name>`) a host materialises from the user's public identity via a contract-shipped realization module. The contract realizes the *account*; the account's *powers* (privileged groups, display manager) come from granted features, never from the user's raw declaration.
_Avoid_: account (reserve for the unix system account), profile.

**Contract**:
The small shared flake that declares the schemas both host and user repos depend on — the identity option set, the home-profile meta options, and the feature/capability vocabulary. It is neither host nor user; it is the agreed interface between them, and the only thing that lets a host *deny* a feature it understands.
_Avoid_: api, sdk, common.

**Feature** (capability):
The unit of negotiation between a host and a user: simultaneously what a user **offers**, what a host **grants** or denies, and what pulls a secret. A feature token-gates a slice of the user's bundle (`mkIf` no-op when not granted), mirroring the NixOS profile model ([ADR-0013](docs/adr/0013-uniform-bundle-consumption.md)). Its packages, config, and secret all flow through one grant gate.
_Avoid_: flag, module (the gate is not itself a module).

**Grant** / **Offer**:
A user **offers** a feature it *can* provide; a host **grants** it by explicitly enabling it (`custom.users.<user>.granted.<feature>`). Default-closed: an ungranted feature is off, and "deny" is simply the absence of a grant. Granting a feature is also what re-keys that feature's secret to the host — so **public identity travels with the user; secrets follow features**, and a host that grants nothing private holds no private key material.

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
