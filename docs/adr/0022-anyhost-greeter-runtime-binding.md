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
  operator-trusted set (your own user repos roaming across your own hosts). The threat is
  "my own repo is buggy/stale," not adversarial: restricted eval (no-IFD, locked inputs)
  guards *accidents*; builds use the normal daemon sandbox + trusted substituters; the home
  is **persisted** (it's you).
- **Tier 2 — untrusted (anyone). Designed-for, deferred.** Any flake URL. Now it's "run a
  stranger's Nix on my hardware": **hardened** eval (enforced no-IFD, restricted builtins so
  no arbitrary `builtins.fetch*`, eval resource limits against DoS), builds under cgroup +
  closure limits with trusted-substituters-only, and an **ephemeral** account (tmpfs home,
  wiped on logout). This is research-grade and explicitly out of scope to *build* now; the
  design only has to leave the knobs where Tier 2 can turn them up.

## The runtime binding flow

A seat host's greeter (greetd + a custom greeter):

1. **Prompt** — flake URL, username, password.
2. **Classify** the URL → Tier 1 (trusted set) or Tier 2.
3. **Evaluate** the flake → the user's manifest (the home-manager module emitting
   `contract.requests` + the `identity`), under the tier's eval posture.
4. **Authenticate** — verify the password against the manifest's `identity.hashedPassword`.
   The flake URL + the password together prove "this is my repo and I am its owner"; there is
   no separate password store.
5. **Grant** — the host auto-grants the user the **safe set** (today `gui` ⇒ desktop). The
   grant is computed at runtime but flows through the *same* contract umbrella + `hostFacts`
   projection as a build-time grant, so the resulting home is identical to an
   operator-granted one.
6. **Build** the user's home (sandboxed per tier).
7. **Provision** the account (persisted for Tier 1 / ephemeral for Tier 2) and start the
   session.

## Decisions that follow from the tier model

- **Persistence is a tier property**, not a separate choice: Tier 1 persisted, Tier 2
  ephemeral. (Tier 1 may later expose an opt-in ephemeral mode, but the default is persisted.)
- **Auth is the manifest's `identity.hashedPassword`** — the credential already lives in the
  contract identity schema; the greeter verifies against it. No new secret store.
- **Which hosts: seat hosts, by *incapacity* not ban.** A headless host has no display, so the
  greeter affordance simply does not exist there — it is not a deny rule. A seat host enables a
  `greeter` profile (greetd + the binding command); this is where the disabled `regreet`
  profile gets extended.

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
