# The user flake shape and `bindUser`

The greeter ([ADR-0022](0022-anyhost-greeter-runtime-binding.md)) binds an *external* user
flake — which forced the question the in-repo phase deferred (the "user surface becomes a
flake emitting requests," ADR-0018's deeper slice-14): **what does a user repo export, and how
does a host turn it into a running user?** This ADR fixes that shape. It is the prerequisite
for the greeter and the design `users/inkpotmonkey/` will be split out to follow.

## What a user flake exports

A user flake is a **home-manager config repo** with three parts:

1. **`identity.json`** — a contract-conventional *data file* (`{name, email, sshKey,
   hashedPassword, username}`), **not Nix**. The home module loads it (`fromJSON`) so it owns
   it; the host/greeter read the *same file* with `jq`. Data, not code, because the greeter must
   **authenticate before evaluating any of the user's Nix** — evaluating an untrusted home
   module runs every module body (IFD, `builtins.fetch*`, non-termination; eval is not a
   sandbox), so auth runs on inert data. (See ADR-0022 for the auth + signature flow.)
2. **A contract-parameterized home module** — it *uses* contract-declared options
   (`custom.home.profiles.*`) and *emits* host-affecting **requests** in the `contract.requests`
   namespace (`gui.session = "x11"`, …), but imports **no** contract and writes **no** system
   config. It is parameterized (`{ config, lib, hostFacts, ... }`); something else supplies the
   contract and pkgs.
3. **Its overlays** (and its own `flake.lock`). The home builds with the user's **own pkgs**
   (not `useGlobalPkgs`), so overlays — which are `nixpkgs → nixpkgs`, i.e. arbitrary code —
   materialize only in the user's *sandboxed* home build, never the host's system pkgs.

The user flake's own `inputs` (`contract`, `nixpkgs`, `home-manager`) exist **only for
standalone dev** — so the user can build/test the repo in isolation. When *bound*, they are
irrelevant: the binding supplies the canonical versions (below).

## `bindUser`: one mechanism, both paths

The host repo exposes a single **`bindUser { userFlake, grants }`**, called by *both* binding
paths (ADR-0018: one mechanism, opposite defaults). It:

- sets `custom.users.<u>.identity = fromJSON userFlake/identity.json` → the contract realization
  materializes the **system account**;
- imports `contract.homeModules.default` (the **host's** contract) **+** the user's home module
  into one `home-manager.users.<u>` config, injecting `pkgs` (host-following, below) and
  `hostFacts`;
- after the home evaluates, **harvests** `config.contract.requests` and applies only the
  **granted** ones to the system (`custom.users.<u>.gui.session = requests.gui.session` iff gui
  granted; ungranted ⇒ inert).

- **Build-time path:** `hosts/default.nix` calls `bindUser` with the operator's data grants
  (default-closed).
- **Runtime path:** the greeter calls the *same* `bindUser` with `grants = safeSet`
  (default-open over the safe set). The greeter is not a parallel codepath.

## Decisions (with the trade-off each settled)

- **identity as a data file, not Nix** — eval-free auth beats "it's all one home-manager module";
  the aesthetic of total consolidation loses to data-before-code (the whole greeter threat model).
- **requests are Nix, identity is data** — split by *when consumed*: identity pre-auth (inert),
  requests post-auth (the host is already evaluating the home).
- **one `bindUser`** — the runtime path is `bindUser` with a runtime-computed grant, not its own
  code, so a build-time- and a greeter-bound user realize identically.
- **own-pkgs for portable users** — packages are the user's self-contained concern and overlays
  stay sandboxed to the user's home; the cost is bounded by making the user's `nixpkgs` follow /
  be host-overridable to the host's pin (shared base; only overlaid packages rebuild).
- **the binding supplies the contract** — the user *writes against* the interface, `bindUser`
  *provides* the host's implementation, so two independent contract pins can never disagree.

## Consequences

- This makes the deferred slice-14 concrete: the user surface is a home-manager repo emitting
  `contract.requests`, harvested across the boundary by `bindUser` — no system slot.
- `users/inkpotmonkey/` splits into a repo of this shape; `users/identity.nix`'s host glue
  becomes `bindUser`, and the home modules drop `useGlobalPkgs` + the host-applied overlays in
  favour of the user flake's own pkgs.
- The contract gains a small surface: the `identity.json` convention (path + schema + a loader)
  and the `contract.requests` namespace in the home module.
- First tracer bullet: a headless `bindUser` over a minimal example user flake (eval the home
  against the contract → read `identity.json` → safe-set grant → produce the home-activation
  package), *before* the greetd UI and the runtime account-provisioning helper.
