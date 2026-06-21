# The anyHost greeter: tiered runtime binding of a user from a flake URL

The project's north star ([ADR-0018](0018-user-confinement-manifest-greeter.md)): any seat
host runs a **greeter** that takes a **flake URL + username + password** and transparently
enables that user — gui by default. This is the **runtime** binding path, the twin of the
operator-authored build-time path (`hosts/default.nix`). Both drive the *same* contract,
manifests, and feature modules ([ADR-0020](0020-extract-contract-flake.md)); the difference
is the default: build-time is **default-closed** (the operator grants explicitly), the
greeter is **default-open over the safe set** — a logging-in user is auto-granted every
runtime-eligible feature, and privilege is impossible because the safe set excludes it
(`safeSet = ["gui"]` today; secret-bearing and privileged-group features are build-time-only,
ADR-0018 slice 15).

The manifest confinement (slices 10–16) makes the *resulting system* safe. It does **not**
make *evaluating and building an external flake at login* safe — a second, harder threat
model, and the substance of this work.

**Decision: a tiered greeter.** The greeter classifies the flake URL into a trust **tier**,
and the tier is a *parameter* over one mechanism — eval strictness, build limits, and home
persistence are knobs the tier sets, not separate code paths:

- **Tier 1 — semi-trusted (own identities). Built now.** The flake URL is in the host's
  operator-trusted set — concretely, the repo is **signed by a registered key** (the public
  half lives in the user's `identity.json`; the greeter verifies the signature over the whole
  tree before evaluating anything). The threat is "my own repo is buggy/stale," not
  adversarial: restricted eval (no-IFD, locked inputs) guards *accidents*; builds use the
  normal daemon sandbox + trusted substituters; the home is **persisted** (it's you). Signing
  is what makes "semi-trusted" concrete — a verified signature proves *this exact config is
  mine, untampered* — but it is **authenticity + integrity, not safety**: a signed config can
  still be buggy, so restricted eval still applies.
- **Tier 2 — untrusted (anyone). Designed-for, deferred.** Any flake URL. Now it's "run a
  stranger's Nix on my hardware": **hardened** eval (enforced no-IFD, restricted builtins so
  no arbitrary `builtins.fetch*`, eval resource limits against DoS), builds under cgroup +
  closure limits with trusted-substituters-only, and an **ephemeral** account (tmpfs home,
  wiped on logout). This is research-grade and explicitly out of scope to *build* now; the
  design only has to leave the knobs where Tier 2 can turn them up.

## The runtime binding flow

A seat host's greeter (greetd + a custom greeter). The ordering is **data before code** —
authenticate on inert data *before* running any of the user's Nix:

1. **Prompt** — flake URL, username, password.
2. **Fetch source only** — fetch the repo tree (`git`/`nix flake prefetch`) **without
   evaluating its outputs**.
3. **Authenticate, eval-free** — read the contract-conventional **`identity.json`** with `jq`
   (no Nix) and verify the password against `identity.hashedPassword`; for Tier 1, also
   **verify the repo signature** against the key in `identity.json` (whole-config authenticity).
   This completes auth having run **zero lines of the user's Nix** — because evaluating an
   untrusted home module runs every module body (IFD, `builtins.fetch*`, non-termination).
4. **Classify** → Tier 1 (signed/trusted) or Tier 2 (untrusted), selecting the eval posture.
5. **Evaluate** the home module under the tier's eval posture → its `contract.requests`.
6. **Grant** — the host auto-grants the **safe set** (today `gui` ⇒ desktop), and harvests the
   *granted* requests. The grant flows through the *same* contract umbrella + `hostFacts`
   projection as a build-time grant, so the resulting home is identical to an operator-granted one.
7. **Build** the user's home (sandboxed per tier).
8. **Provision** the account (persisted for Tier 1 / ephemeral for Tier 2) and start the session.

## Decisions that follow from the tier model

- **Persistence is a tier property**, not a separate choice: Tier 1 persisted, Tier 2
  ephemeral. (Tier 1 may later expose an opt-in ephemeral mode, but the default is persisted.)
- **Auth is eval-free, on `identity.json` + signature.** The credential lives in the user
  repo's `identity.json` (data, not Nix), so the greeter reads it with `jq` and verifies the
  password *before* evaluating any of the user's Nix; Tier 1 additionally verifies the repo
  signature against the key in `identity.json`. No new secret store. (A *public* user repo
  exposes `hashedPassword` publicly, so it must be a strong hash — a property of putting
  identity in a fetchable repo, not of the file form.)
- **Which hosts: seat hosts, by *incapacity* not ban.** A headless host has no display, so the
  greeter affordance simply does not exist there — it is not a deny rule. A seat host enables a
  `greeter` profile (greetd + the binding command); this is where the disabled `regreet`
  profile gets extended.
- **Secrets degrade gracefully.** A greeter-bound home must *build and activate without the
  user's private key* — secret-bearing parts gate on the grant/key and go dormant when absent
  (as `git.nix` already falls back to `~/.ssh` without the `signing` grant). Contract
  secret-features satisfy this via the safe set; the user's personal secrets must gate likewise.
  A greeter-bound user gets a secret-free baseline; full secrets need the build-time path (where
  the key lives). Restoring secrets at a greeter is deferred ([issue 19](../../.scratch/host-user-contract/issues/19-greeter-secret-provisioning.md)).
- **Portable users build their home with their *own* pkgs, not `useGlobalPkgs`.** Packages are
  the user's self-contained concern; overlays are `nixpkgs → nixpkgs` (arbitrary code), so a user
  must never *request* one — instead the user flake carries its overlays and they materialize
  only in the user's *own* home build (sandboxed), never the host's system pkgs. Cost is a
  function of nixpkgs divergence: a fully independent nixpkgs duplicates a whole closure
  (gigabytes) + a second per-login eval; so the user flake's `nixpkgs` should **follow / be
  host-overridable to the host's pin**, carrying only overlays — the base closure is shared, and
  the only cost is the overlaid packages' rebuilds (paid anyway) + slightly looser base
  reproducibility.

## The genuinely novel work (what is not off-the-shelf)

- **Runtime user provisioning.** NixOS users are *declarative* (build-time). A greeter binding
  a user at *runtime* must materialize the account + activate the built home OUTSIDE the
  build-time model — a privileged helper that, given the built home-activation package + the
  safe-set grant, creates the (ephemeral or persisted) user and starts the session. Bridging
  the declarative contract to a runtime-provisioned login is the crux.
- **Restricted eval at login.** `restrict-eval` + no-IFD + locked-inputs-only + eval limits,
  applied to an *external* flake at login. Tier 1 needs the accident-guarding subset; Tier 2's
  hardened, adversarial version is the deferred research part.

## Considered Options

- **Untrusted-only (build the hard thing first)** — rejected: research-grade sandboxing would
  gate the useful feature indefinitely.
- **Semi-trusted-only (ignore strangers)** — rejected: cheap now, but bakes "trusted" into the
  mechanism, so adding strangers later is a rewrite, not a knob.
- **Tiered (chosen)** — build Tier 1, parameterize for Tier 2. Ships the north star now; the
  threat model stays honest and Tier 2 is an additive turn of the knobs.

## Consequences

- The greeter is genuinely novel — a greetd greeter that evals a flake and provisions a user at
  login does not exist off-the-shelf. The first tracer bullet is therefore the **eval-binding
  core** (eval the manifest → verify the password → compute the safe-set grant → build the home
  activation package), proven headless on a seat host, *before* the greetd UI and the privileged
  runtime-provisioning helper.
- Tier 2 (untrusted) is deferred but designed-for; its hardened eval + ephemeral provisioning is
  tracked as future work, not a blocker.
- Portable kanata ([slice 18](../../.scratch/host-user-contract/issues/18-kanata-portable-user-feature.md))
  stays build-time-only — a `kanata-with-cmd` keymap is host-executed user code (an exec payload),
  so it is excluded from the safe set and a greeter never grants it.
