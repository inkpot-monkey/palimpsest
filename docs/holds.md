# Holds

Packages this fleet holds back from a flake bump **because something upstream has to change
first**. Each entry carries a machine-runnable `probe` and a human `release condition`; a daily
agent on rk1b runs the probes and writes its findings back here. See
[ADR-0038](adr/0038-held-back-packages-are-a-registry-an-agent-rechecks.md).

**Scope — only things that can become false.** A hold is a wait, not a preference. Deviations
from upstream that no upstream event can ever clear are *standing laws* and do not live here:
porcupineFish's `stable_*` vendor kernel (`AGENTS.md`, `hosts/porcupineFish/README.md`),
`jmap-bridge`'s release-tag pin (ADR-0016), music-assistant's two `disabledTests`
(`modules/nixos/profiles/music-assistant.nix` — both belong to providers this host does not run,
so the condition for re-enabling them is a local decision, not an upstream fix). A registry that
mixes a to-do list with a law book is a law book nobody finishes reading.

**One owner.** The agent writes this file and nothing else. It never touches a pin — dropping a
hold is a human action.

## Probe vocabulary

Closed, and deliberately mirroring nvchecker's source types so these translate mechanically if
the deterministic watcher is ever built:

| Form | Trips when |
| -------------------------------- | --------------------------------------------------------------- |
| `nixpkgs-attr:<attr>` | the attribute's version in nixos-unstable differs from the pin |
| `github-release:<owner>/<repo>` | a release newer than the recorded one exists |
| `github-issue:<owner>/<repo>#<n>`| the issue/PR closes |
| `url-regex:<url> <regex>` | capture group 1 differs from the recorded value |
| `cmd:<shell>` | **discouraged escape hatch** — exit 0 means tripped |

A tripped probe is not a ready hold. It means *go and read the release condition*.

## Held

### matrix-tuwunel

- **what & where** — `modules/shared/overlays/default.nix`, the `stable-until-fixed` overlay:
  taken from `nixpkgs-stable` (26.05) instead of unstable. Not a downgrade — stable carries the
  same 1.9.4 and substitutes it, where the unstable path 404s.
- **why** — on unstable the build dies in `aws-lc-sys`'s build script:
  `AWS_LC_SYS_USE_SYSTEM=1 requires a system-installed AWS-LC, but none was found`. nixpkgs is
  midway through moving Rust `*-sys` crates onto system libraries via `default-crate-overrides`,
  and every dependent package has to gain that library in `buildInputs` one at a time.
- **probe** — `cmd:test 200 = "$(curl -s -o /dev/null -w '%{http_code}' https://cache.nixos.org/$(basename "$(nix eval --raw github:NixOS/nixpkgs/nixos-unstable#matrix-tuwunel.outPath)" | cut -c1-32).narinfo)"`
  — a 404 narinfo on the unstable path means it is still broken; a 200 means someone built it.
- **release condition** — the unstable package builds **and porcupineFish/kelpy actually build
  against it**, not merely evaluate. Every entry in this overlay deliberately breaks the
  module-and-package-from-one-pin rule, and this repo has already been bitten by module/package
  skew (see the paperless note in `modules/nixos/profiles/paperless.nix`). Drop the attr from the
  overlay and build the host.
- **rejected** — two alternatives were written and thrown away, and they apply to all three
  `stable-until-fixed` entries. **A frozen rev** (the pre-bump unstable) stops receiving security
  fixes, and these three are a federated homeserver, a mail server and a bridge — the worst
  possible set to abandon; it was also strictly worse on version, pinning tuwunel back to 1.9.3.
  A release branch keeps getting backports. **An overlay adding the missing `buildInputs`** is
  what upstream is doing and does work, but the result is in no cache, so every deploy would
  compile three large Rust trees from source.
- **upstream** — [NixOS/nixpkgs#570938](https://github.com/NixOS/nixpkgs/issues/570938) (Tracking:
  vendored copies of aws-lc in Rust crates), under
  [#570943](https://github.com/NixOS/nixpkgs/issues/570943). Also
  `gh search commits --repo NixOS/nixpkgs matrix-tuwunel`.
- **opened** — 2026-11-10 (`8c651f1`)
- **last checked** — never
- **status** — held
- **last finding** — _(none yet)_

### stalwart

- **what & where** — `modules/shared/overlays/default.nix`, the `stable-until-fixed` overlay.
  Stable carries the same 0.15.5 and substitutes it.
- **why** — `zstd-sys`, reached via `trunk` → `webadmin`:
  `The system library 'libzstd' required by crate 'zstd-sys' was not found`. Same
  `*-sys` → system-library migration as matrix-tuwunel.
- **probe** — `cmd:test 200 = "$(curl -s -o /dev/null -w '%{http_code}' https://cache.nixos.org/$(basename "$(nix eval --raw github:NixOS/nixpkgs/nixos-unstable#stalwart.outPath)" | cut -c1-32).narinfo)"`
- **release condition** — the unstable package builds and kelpy builds against it. Stalwart is the
  mail server, so this one also wants a mail round-trip after the switch, not just a green build:
  it reads its certificate at startup and has previously served a superseded one.
- **rejected** — as matrix-tuwunel: a frozen rev rots, a `buildInputs` overlay is in no cache.
- **upstream** — [NixOS/nixpkgs#570944](https://github.com/NixOS/nixpkgs/issues/570944) (Tracking:
  vendored copies of zstd in Rust crates). Also
  `gh search commits --repo NixOS/nixpkgs "trunk zstd"`.
- **opened** — 2026-11-10 (`8c651f1`)
- **last checked** — never
- **status** — held
- **last finding** — _(none yet)_

### matrix-hookshot

- **what & where** — `modules/shared/overlays/default.nix`, the `stable-until-fixed` overlay.
  Stable carries the same 7.6.0 and substitutes it.
- **why** — `libsqlite3-sys`, reached via `matrix-sdk-crypto-nodejs`, fails at the final link:
  `ld: cannot find -lsqlite3`. Same migration again.
- **probe** — `cmd:test 200 = "$(curl -s -o /dev/null -w '%{http_code}' https://cache.nixos.org/$(basename "$(nix eval --raw github:NixOS/nixpkgs/nixos-unstable#matrix-hookshot.outPath)" | cut -c1-32).narinfo)"`
- **release condition** — the unstable package builds and kelpy builds against it. Hookshot is the
  path `#infra-alerts` arrives by, so a silent failure here is the fleet going quiet rather than
  anything visibly breaking — check a webhook actually lands.
- **rejected** — as matrix-tuwunel: a frozen rev rots, a `buildInputs` overlay is in no cache.
- **upstream** — [NixOS/nixpkgs#570940](https://github.com/NixOS/nixpkgs/issues/570940) (Tracking:
  vendored copies of sqlite in Rust crates).
- **opened** — 2026-11-10 (`8c651f1`)
- **last checked** — never
- **status** — held
- **last finding** — _(none yet)_

### stump

- **what & where** — `flake.nix`, the `nixpkgs-frozen` input (rev `7a0f122f`, the fleet's
  pre-2026-11-09 nixpkgs), consumed by the `stump-pin` overlay in
  `modules/shared/overlays/default.nix`. `callPackage`d from the frozen set, *not* an override of
  the `additions` package — the point is to evaluate `pkgs/stump` against the frozen stdenv and
  `rustPlatform`.
- **why** — the same `*-sys` migration, but it cannot be solved the way the three above were:
  stump is not in the stable branch and `pkgs/stump` is our derivation, so there is no upstream
  binary to borrow. The migration takes two bites — `zstd-sys` fails first in a build script, and
  ~20 minutes later `libsqlite3-sys` fails at the final link. Built against the frozen rev it
  reproduces `dgfx0q5dmk5gvhnvfx6szqw1s6vjgp0v-stump-0.1.6`, byte-identical to what rk1b already
  runs, so the pin costs no build on the fleet's one aarch64 builder.
  **The cost:** this freezes stump's entire dependency closure at 2026-09-28, openssl and sqlite
  included. Acceptable only because stump is the tailnet-only reading catalog — it is still a
  frozen network service and should not sit here indefinitely.
- **probe** — `github-issue:NixOS/nixpkgs#570943` (the umbrella tracking issue for the whole
  `*-sys` → system-library migration).
- **release condition** — add `zstd` and `sqlite` to `pkgs/stump`'s `buildInputs`. That commit is
  in history at `fd96490`, reverted alongside this pin because carrying it changes the derivation
  hash and reintroduces the from-source build. Do it when nixpkgs settles, **or** when stump needs
  a version bump anyway — at which point it has to be rebuilt regardless and the pin buys nothing.
  While the pin stands, `pkgs/stump` must stay free of those `buildInputs`.
- **rejected** — `nixpkgs-stable`, which worked for the three above: stump is not in the stable
  branch at all. Building `pkgs/stump` against *any* other package set produces a new store path
  and therefore a from-source Rust build on the fleet's single aarch64 builder, which is the
  entire cost this pin avoids.
- **upstream** — [NixOS/nixpkgs#570943](https://github.com/NixOS/nixpkgs/issues/570943),
  [#570944](https://github.com/NixOS/nixpkgs/issues/570944) (zstd),
  [#570940](https://github.com/NixOS/nixpkgs/issues/570940) (sqlite). nixpkgs' own `stump` (0.1.11)
  has neither library in `buildInputs` either, so it is broken the same way — and it pulls in
  gtk3/webkitgtk, which `pkgs/stump` deliberately avoids by building only the server binary.
- **opened** — 2026-11-10 (`aaebec1`)
- **last checked** — never
- **status** — held
- **last finding** — _(none yet)_

### snapcast

- **what & where** — pinned to 0.34.0 fleet-wide by the `snapcast` overlay in
  `modules/shared/overlays/default.nix`. Only porcupineFish actually pulls it into a closure.
- **why** — Music Assistant 2.9.x/2.10.x drives an *external* snapserver and is developed and
  tested against 0.34.0 (its `Dockerfile.base` sets `ARG SNAPCAST_VERSION=0.34.0`). nixpkgs'
  0.35.0 is a minor ahead of that, unverified, and changes the dynamic `Stream.RemoveStream`
  teardown path MA relies on — 0.30 was broken and 0.32 broke MA per snapcast#1410. The hold is on
  the *tested pairing*, not on snapcast itself.
- **probe** — `nixpkgs-attr:snapcast` (recorded: 0.35.0). Tripping only says nixpkgs moved, which
  is not the question — read the release condition.
- **release condition** — Music Assistant's `Dockerfile.base` names the version nixpkgs has, i.e.
  `ARG SNAPCAST_VERSION` catches up to the pinned attr; **or** a newer pairing is verified on
  porcupineFish itself, which means playing audio and then tearing a stream down, not a green
  build. See [ADR-0031](adr/0031-porcupinefish-sound-server-audio.md).
- **upstream** — [badaix/snapcast#1410](https://github.com/badaix/snapcast/issues/1410).
  Release condition is checkable with
  `url-regex:https://raw.githubusercontent.com/music-assistant/server/dev/Dockerfile.base ARG SNAPCAST_VERSION=([0-9.]+)`
  (recorded: 0.34.0 — note the branch is `dev`/`main`, there is no `master`).
- **opened** — 2026-07-24 (`f4e3a40`)
- **last checked** — never
- **status** — held
- **last finding** — _(none yet)_

### flexget-webui

- **what & where** — `modules/shared/overlays/flexget.nix`: a `postInstall` that unzips
  `dist.zip` from the pinned `Flexget/webui` 2.0.29 release into
  `$out/lib/python3.13/site-packages/flexget/ui/v2`.
- **why** — nixpkgs' `flexget` does not ship the WebUI v2 assets at all, so the web interface is
  simply absent without this. The assets are a separate repo with its own release cadence, which
  is why the fetch is pinned rather than tracking anything.
- **probe** — `github-release:Flexget/webui` (recorded: 2.0.29, 2023-08-19).
- **release condition** — nixpkgs' `flexget` package ships `ui/v2/dist` itself, at which point the
  whole overlay is deleted rather than bumped. A tripped probe means something weaker and more
  likely: a newer `dist.zip` to re-pin, which also needs the hardcoded `python3.13` path in the
  overlay rechecked against whatever Python nixpkgs' flexget is on.
- **upstream** — none filed.
- **opened** — 2026-03-19 (`14b8795`)
- **last checked** — never
- **status** — held
- **last finding** — _(none yet)_

### blocky

- **what & where** — `modules/nixos/profiles/blocky.nix` sets
  `services.blocky.package = inputs.nixpkgs.legacyPackages.<system>.blocky`, forcing the fleet's
  unstable blocky on every host rather than letting each host use its own nixpkgs.
- **why** — this is a forward pin, not a held-back one, and it exists for the Pi: the pinned
  `nixos-raspberrypi` toolchain carries its own nixpkgs (0.29.0 at the current lock) whose
  `hostsFile` handling differs — it does not serve local `hostsFile` entries the same way, which
  would break the runtime-regenerated Tailscale service resolution this profile depends on. kelpy
  already tracks unstable; this aligns the Pi. The `hostsFile.sources`-only schema in that profile
  is the one form valid across both blockys and must stay that way while this stands.
- **probe** — `cmd:test "$(nix eval --raw github:NixOS/nixpkgs/$(nix flake metadata --json | jq -r '.locks.nodes[.locks.nodes["nixos-raspberrypi"].inputs.nixpkgs].locked.rev')#blocky.version)" = "$(nix eval --raw github:NixOS/nixpkgs/nixos-unstable#blocky.version)"`
  — tripped when the Pi toolchain's nixpkgs and unstable agree on a blocky version (recorded:
  0.29.0 vs 0.35.0).
- **release condition** — the `nixos-raspberrypi` pin's nixpkgs carries a blocky that serves
  `hostsFile` entries the way the dynamic service resolution needs. Verify on porcupineFish by
  resolving a tailnet service name through blocky directly (not `getent` — it answers from the
  stub resolver and hides blocky's reply). Bumping the `nixos-raspberrypi` rev is itself expensive
  and kernel-gated, so this clears as a side effect of a toolchain bump, never on its own account.
- **upstream** — none; this clears when the `nixos-raspberrypi` pin moves. See
  `hosts/porcupineFish/README.md`.
- **opened** — 2026-06-11 (`a48a8c5`)
- **last checked** — never
- **status** — held
- **last finding** — _(none yet)_

## Cleared

Cleared holds are archived here, never deleted — the expensive knowledge in a hold is the
negative result, and a deleted hold means the next person re-pins blind or walks into the same
wall.

_(none yet)_
