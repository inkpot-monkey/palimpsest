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

> Target architecture being designed: hosts and users split into separate repos bound by a shared contract, so any host can enable a user and on rebuild they transparently work, while hosts can deny features a user introduces. See [ADR-0015](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0015-host-user-contract.md). Today `users/` still lives in this repo; these terms fix the language the migration aims at.

**User**:
A portable bundle of *public identity + home config + its own secrets + grantable features*, owned in its own repo. Distinct from the **system account** (`users.users.<name>`) a host materialises from the user's public identity via a contract-shipped realization module. The contract realizes the *account*; the account's *powers* (privileged groups, display manager) come from granted features, never from the user's raw declaration.
_Avoid_: account (reserve for the unix system account), profile.

**Contract** (the *contract kit*):
The small shared flake both host and user repos depend on. More than schemas: it ships (1) the **schema** — the identity option set, home-profile meta, the feature/capability vocabulary, and the `platform` *interface*; (2) the host-invariant **realization** that turns the schema into a system account with powers from grants; (3) the **derivation logic** (e.g. recipients-from-grants); and (4) a **conformance suite** that proves the patterns across synthetic hosts × users. It is neither host nor user; it is the agreed interface between them, and the only thing that lets a host *deny* a feature it understands. The host supplies only the *implementation* of the **platform interface** (its secrets backend) — that stays host-side. Delivered as a registry-baked **kit** — its modules close over their own feature registry, so they depend on nothing but nixpkgs `lib` and never on the consuming host's `self`. It now lives in its **own public repo**, `github:palebluebytes/host-user-contract`, consumed as a flake input (`nixpkgs.follows`); edit behaviour THERE, then `nix flake update contract` here ([ADR-0020](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0020-extract-contract-flake.md)).
_Avoid_: api, sdk, common.

**Platform interface**:
The contract's seam to a host's secrets backend: a feature declares a *logical* secret and reads its resolved **runtime path**, never naming the backend. The contract ships the typed *interface*; the host supplies the *binding* — the only place a backend (sops, agenix, …) is named — so backends are interchangeable and the contract stays secret-free. It abstracts secret *provisioning*, not merely file location: a path-locator plus a key-selector would be a sops abstraction wearing a neutral name ([ADR-0021](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0021-platform-backend-agnostic-secrets.md)).
_Avoid_: secrets backend (that is the host's *implementation* of this interface, not the interface itself).

**Feature** (capability):
The unit of negotiation between a host and a user: simultaneously what a user **offers**, what a host **grants** or denies, and what pulls a secret. A feature token-gates a slice of the user's bundle (`mkIf` no-op when not granted), mirroring the NixOS profile model ([ADR-0013](docs/adr/0013-uniform-bundle-consumption.md)). Its packages, config, and secret all flow through one grant gate.
_Avoid_: flag, module (the gate is not itself a module).

A feature has two faces, kept distinct: the **grant** (host-owned) and its **feature configuration** (user-owned).

**Grant** / **Offer**:
A user **offers** a feature it *can* provide; a host **grants** it by explicitly enabling it (`custom.users.<user>.granted.<feature>`). Default-closed: an ungranted feature is off, and "deny" is simply the absence of a grant. The grant is purely the host's yes/no. Granting a feature is also what re-keys that feature's secret to the host — so **public identity travels with the user; secrets follow features**, and a host that grants nothing private holds no private key material.

The grant is the **sole enabler**, and the host must grant *every* host effect — no exceptions. A user can never enable a feature; it can only **offer** one. An offer without a grant is **inert**: the feature's host effects are a silent no-op and the build still succeeds — requesting an ungranted feature is never an error, it simply produces a host without that feature. Consequently `granted.<feature>` is **host-write-only** — a user repo can never set its own grant — and the user contributes no system configuration at all, only data the host's grants draw on (see **User manifest**, **Feature module**, **Binding path**, [ADR-0018](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0018-user-confinement-manifest-greeter.md)).

**Prohibition** vs **Incapacity**:
Two reasons a host lacks a feature, only one of which is a security statement. A **prohibition** is a host *forbidding* a feature it otherwise could run — the security verb (e.g. an exposed host forbidding any secret-bearing feature). An **incapacity** is a host simply not being able to offer it — a *headless* host has no display, so no greeter and no gui, which is a fact about the hardware, not a policy. Do not model incapacity as a ban; it dilutes the one word that carries weight.
_Avoid_: "deny" for both (reserve denial for the absence of a grant; use prohibit for the active security veto).

**Feature configuration**:
The user-provided *parameters* of a feature (e.g. a gui user's **session** preference — Wayland or X11 — or a restic feature's schedule), as opposed to the **grant**, which is the host's yes/no. The realization reads a feature's configuration only when the feature is granted: user-scoped parameters apply per user, while host-affecting ones **aggregate** across all granted users rather than conflict. The gui **session** is the canonical case — on a single-seat host the display surface is the *union* of every granted gui user's session, so two users with different sessions coexist, each logging into their own. (Aggregation only fits parameters that genuinely union; a truly singular setting like the system timezone stays a host decision.)
_Avoid_: settings (too generic), the grant (that is the host's, not the user's).

**User manifest**:
The confined surface a user exposes — a **home-manager config repo**, deliberately: home-manager is already a restricted universe a config cannot escape, and already the portable standalone artifact the greeter fetches. The home module holds the **dotfiles**, the contract **features** it enables, and the host-affecting params those features need, and emits **requests** (see below) — but it never writes host config. The **identity** lives *in the repo* as a contract-conventional **`identity.json`** (a data file, `{name, email, sshKey, hashedPassword, username}`): the home module loads it (`fromJSON`) and so owns it, while the **greeter reads the same file with `jq`** — after fetching the repo *source* but **before evaluating any Nix** — to authenticate. That is the point of a data file over Nix-inline identity: evaluating the untrusted home module runs every module body (IFD, `builtins.fetch*`, non-termination — eval is not a sandbox), so auth must complete on inert data, not code ([ADR-0022](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0022-anyhost-greeter-runtime-binding.md)). It has no system-configuration slot, so `users.users`, `nixpkgs.*`, `boot.*` are not in its universe. Its requests are **host-independent** and harvested **against** a host's grant surface: the host's grants decide which realize. Its home module may *read* host state only through the restricted **hostFacts** projection, never raw `osConfig`. This is what makes a user portable — and what makes evaluating a stranger's flake URL at the greeter's *config* surface safe. See [ADR-0018](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0018-user-confinement-manifest-greeter.md).
_Avoid_: user module (a NixOS module — the manifest is a home-manager module), config.

**Request**:
The declarative data a user manifest emits to ask the host for a feature's host effect — populated in a contract-provided `contract.requests` namespace inside the home-manager evaluation (e.g. `gui.session = "x11"`, a kanata config). A **request is not a write**: the user only *asks*; a contract-owned system integration reads the requests and applies the **granted** ones, aggregating host-affecting ones (the gui-session union reads every granted user's request). An ungranted request is inert. Request payloads for **safe-set** features must be **inert** (no host-executed user code) — an executable payload (a `kanata-with-cmd` keymap) is a code-exec vector and stays build-time-only. See [ADR-0018](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0018-user-confinement-manifest-greeter.md).
_Avoid_: write, set (the user never sets host config; it requests).

**Feature module**:
A **contract-owned** NixOS module carrying a feature's *host effects* (its services, groups, packages, secrets), gated `mkIf granted` and parameterized by the user's emitted **request**. It is the only thing that writes host configuration on a user's behalf — the user manifest never does. Relocating a host effect out of a user and into a feature module is what turns an unbounded "user can set anything" into "the host grants, the contract realizes" (the model-C boundary, [ADR-0015](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0015-host-user-contract.md) mechanic 7, made concrete in [ADR-0018](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0018-user-confinement-manifest-greeter.md)).
_Avoid_: profile (a profile is host- or user-toggled config composition; a feature module is the grant-gated realization of one feature).

**hostFacts**:
The restricted, read-only projection of host state a user manifest's home module may consult to adapt — `{ exposed, platform, granted }` and nothing more. It is **self-scoped** (this user's grants only; never another user's data and never a secret value) and deliberately **excludes `hostName`**, so a user adapts on *semantic* facts, never on host identity. It replaces the raw-`osConfig` read with a surface narrow enough that host-awareness can't become host-coupling. See [ADR-0018](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0018-user-confinement-manifest-greeter.md).
_Avoid_: osConfig (the unrestricted tree it replaces).

**Safe set** (runtime-eligible features):
The features a *runtime* binding — the greeter — may confer on a user without operator authorship: those that confer no privileged group, bear no secret, **and carry an inert request payload** (`¬secretBearing ∧ featureGroups == [] ∧ inertPayload`). It is **derived**, not declared. gui is in it (carrying only the inert `session` request); `workstation` (privileged), `restic`/`signing` (secret-bearing), and a `kanata-with-cmd` keymap (executable payload) are not. The hinge of the model: privilege — and host-executed code — is build-time-only, so a flake URL typed at a greeter can never escalate. See [ADR-0018](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0018-user-confinement-manifest-greeter.md).
_Avoid_: default-granted (describes the disposition, not the membership rule).

**Binding path**:
How a user is bound to a host, of which there are two, with opposite grant defaults *by design*. **Build-time binding** is operator-authored (the fleet declaration) and **default-closed** — the operator grants explicitly, privilege included, subject to prohibitions. **Runtime binding** is the **greeter** (flake URL + username + password) and is **default-open over the safe set** — gui and baseline are auto-granted, privilege is impossible. Both call **one host-side `bindUser`** (feed `identity.json` → the realization's account; wire the contract + user home modules; harvest the granted `contract.requests`) — the greeter is not a parallel codepath, it is `bindUser` with the grant computed at runtime (= the safe set). Both drive the *same* contract, manifests, and feature modules.
_Avoid_: enable (a user is never bound by enabling itself; the host's grant binds).

### Matrix bridging

**The bridge**:
The hand-written Rust `jmap-matrix-bridge` appservice that connects a JMAP mailbox (Stalwart) to Matrix. Unqualified, "the bridge" means this one. It lives in its own repo (`palebluebytes/jmap-matrix-bridge`), consumed here as the `jmap-bridge` flake input; only the host glue (`modules/nixos/profiles/matrix/jmap-bridge.nix`) is in this repo. See [ADR-0017](docs/adr/0017-jmap-bridge-own-repo.md).
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
