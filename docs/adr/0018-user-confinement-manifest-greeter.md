# A user is confined data: the manifest, feature modules, and the anyHost greeter

[ADR-0015](0015-host-user-contract.md) mechanic 7 named the eventual goal — evaluate a
user against a *restricted option universe* so it cannot set arbitrary host options —
and then **deferred** it ("model A in-repo now, model C at the repo split"). This ADR
promotes that deferral into a concrete model, because three things are now true that
were not when 0015 was written: the deferral is **already leaking in-tree**, the
[0016](0016-feature-configuration-aggregates.md) feature-configuration work gave us the
data-vs-effect split the model needs, and a **north-star use case** has appeared that
makes "airtight, not hygienic" non-negotiable — a greeter on any host that takes a
flake URL + username + password and transparently enables that user.

## The decision

**A user is confined to pure data; every host effect it has is owned by the contract
and gated by a host grant.**

- A **user manifest** is the *only* thing a user repo exposes: its public `identity`,
  its `featureConfig`, the features it offers (implicitly — see below), and a
  home-manager module. It has **no system-configuration slot**. `users.users`,
  `nixpkgs.*`, `boot.*`, `sops.*` are not in its universe, so they are unsettable by
  construction, not by review.
- Every host-side effect a feature has (its services, groups, packages, secrets) lives
  in a **feature module** — a contract-owned NixOS module, gated `mkIf granted` and
  parameterized by the manifest's `featureConfig`. The user never writes host config;
  the contract does, on the user's behalf, only where granted.
- The boundary is enforced by **structural confinement** (the user has no module slot —
  "model C") backed by **restricted `lib.evalModules`** (the manifest is evaluated
  against a universe declaring only the contract's user-facing options — "model A
  enforcement"). The home side needs no new enforcement: home-manager is *already* a
  restricted `evalModules` universe — a home config physically cannot reach system
  state — which is the existing proof that this enforcement model works.

This closes three leaks present in the in-tree "model A" posture today:

1. **The clamp bypass.** The slice-04 clamp filters `identity.extraGroups`, but
   `users/inkpotmonkey/nixos/default.nix` writes `users.users.inkpotmonkey.extraGroups`
   *directly* with `disk`, `qemu-libvirtd`, `libvirtd` — privileged groups — which
   list-merge in past the clamp. A pure-data manifest has no `users.users` to write.
2. **The self-grant.** The `gui` variant sets
   `custom.users.inkpotmonkey.granted.gui.enable = true` — a user module granting its
   own feature. `granted.*` becomes **host-write-only**; a manifest cannot touch it.
3. **The raw-`osConfig` read.** The home module reads the entire system config tree to
   adapt; it should see only a restricted projection (below).

## The grant is the sole enabler; degradation is silent

The host must grant **every** host effect, no exceptions. A user can never *enable* a
feature — only *offer* one. An offer without a grant is **inert**: the feature module is
a `mkIf granted` no-op, so requesting an ungranted feature is never an eval error — it
simply produces a host without that feature, and the build succeeds. Offers are
**implicit** (a manifest carrying `featureConfig.gui.*` is offering gui); no formal
`offers` field is introduced until the separate-repo future makes "what is on this
user's menu?" un-answerable by inspection.

## Host-awareness is read-only, through a restricted `hostFacts` projection

A manifest's *data* is host-independent, but its home module legitimately **adapts** to
the host (today `git.nix` falls back when the signing key is absent). That adaptation is
**read-only** and flows through a contract-defined projection — never raw `osConfig`:

```
hostFacts = { exposed : bool; platform : str; granted : { <feature> = bool } }
```

It is **self-scoped** (this user's grants only — never another user's identity, grants,
or secrets, and never a secret value). `hostName` is **deliberately excluded**: branching
on host *identity* is the model-A coupling that defeats "works on any host," so the
projection forces adaptation onto *semantic* facts. This converts the last identity
branch — the signing key gated on `hostName ∈ {kelpy, stargazer, sawtoothShark}` — into a
`signing` **feature**: those hosts *grant signing* instead of being named in a list. If a
genuine need for a stable build-time device name appears, a narrow `deviceName` fact is
added deliberately, rather than re-opening raw `hostName`.

## Two binding paths, opposite defaults by design — the greeter north star

The end goal is that **any host runs a greeter** taking a flake URL + username +
password and **transparently enabling** that user, with **gui as the default** unless the
host opts out. This looks like it contradicts 0015 mechanic 2's *default-closed* grant,
but it does not — the two defaults belong to **two binding paths** over the *same*
contract, and the opposite defaults are correct:

- **Build-time binding** (operator-authored, the `manyHost` fleet declaration):
  **default-closed allow-list.** The operator grants what they mean to, privilege
  included, subject to the exposed-host prohibition.
- **Runtime binding** (the greeter): **default-open over the *safe set*.** A user logging
  in via flake URL is auto-granted every *runtime-eligible* feature. gui is "the default"
  here because it is runtime-eligible — not because of a flag.

**Runtime-eligibility is derived, not declared** — a feature is in the safe set iff it
confers no privileged group and bears no secret:

```
runtimeEligible(f)  ⟺  ¬featureMeta.f.secretBearing  ∧  featureGroups.f == []
```

Both inputs already exist (`privilegedGroups`/`featureGroups`, `secretBearing`), so the
**security hinge** falls out with no new trust knob:

> **Privilege is build-time-only. The runtime greeter confers only the safe set — a
> stranger off a flake URL gets a desktop and their own home, and can *never* obtain
> docker/wheel/secrets/signing.**

This forces a cleanup we need regardless: for gui to be in the safe set it must confer
only non-privileged groups (`input`, `uinput`, `video`, `plugdev`, `dialout`); the
virtualization groups (`disk`, `libvirtd`, `qemu-libvirtd`) that leaked into the gui
block become their own **default-denied, build-time-only** feature. The model turns leak
#1 into a structural boundary.

We also keep two host-side notions distinct, because only one carries security weight:

- **Incapacity** — a *headless* host (kelpy, rk1a, a Pi) has no display, so no greeter,
  so the runtime path simply does not exist there. This is not a "ban."
- **Prohibition** — a host *forbidding* a feature it otherwise could run (the generalized
  exposed-host rule). This is the security verb; do not dilute it by modeling "no screen"
  as a ban.

## Consequences

- **The confinement model is built now and stands on its own**, independent of the
  greeter: it closes the three in-tree leaks above and is the non-negotiable prerequisite
  for runtime binding. Nothing in it is speculative.
- **`manyHost` / `manyUser` become one mechanism.** A user manifest evaluated against a
  host's explicit grant surface is simultaneously the *assembly* (it produces a
  `nixosConfiguration`), the *conformance matrix* (every pairing is an eval to assert
  over), and the *enforcement* (the manifest can contribute nothing the host did not
  grant). Today's `hosts/default.nix` shifts from implicit *grant-by-which-module-you-import*
  to explicit *grant-as-data*.
- **Migrating a host effect is mechanical but not free**: every write in a user's
  `nixos/` module is relocated into a contract feature module, parameterized by
  `featureConfig`. The contract becomes a **curated capability catalog** (0015 mechanic 7's
  cost), and re-exposing options at the catalog edge re-litigates
  [0014](0014-home-profiles-conditional-import.md)'s home-manager version skew.
- **`permittedInsecurePackages` and overlays move host-ward.** A user can no longer relax
  a host-wide security gate; if a granted feature needs an insecure package or an overlay,
  the *feature module* declares it and the host's grant is its acceptance.

## Threat model: the greeter's untrusted-eval surface is a *separate*, deferred problem

Config-confinement is **necessary but not sufficient** for the greeter, and this ADR does
not claim otherwise. Everything above makes the *resulting system* safe; none of it makes
*evaluating and building an untrusted flake at login* safe — which is exactly what the
greeter does on demand:

- Nix **eval** of a stranger's flake can trigger import-from-derivation, arbitrary
  `builtins.fetch*`, and pathological evaluation (DoS).
- Nix **build** runs the flake's builders via the daemon — sandboxed, but the sandbox is
  a kernel boundary, not a proof, and the closure/resource cost is attacker-controlled.
- Substituters and inputs are attacker-named unless pinned.

That is a second, harder threat model (restricted eval: no-IFD + restricted builtins +
locked inputs; sandboxed builds; trusted-substituters-only; cgroup/closure limits;
ephemeral unprivileged accounts), and it is **orthogonal** to manifest confinement. Its
size hinges on a question to be answered when it is taken up: **is the greeter for one's
*own* federated identities roaming across *one's own* hosts (semi-trusted flake URLs), or
genuinely anyone (untrusted)?** The first is a tractable personal-fleet feature; the
second is "run arbitrary strangers' Nix on my hardware," a research-grade sandboxing
problem. It is therefore **quarantined into its own future ADR**, gated on that question,
rather than allowed to block the confinement work — which is ready, valuable, and the
foundation the greeter will stand on.

## Considered alternatives

- **Allowlist assertion (keep model A, lint the option-paths a user contributes)** —
  rejected as the *boundary*: it is a post-hoc check over an already-merged evaluation, so
  it is approximate and races the very merges it polices. It can be a transitional
  *backstop* while the catalog is built, but not the guarantee.
- **A manual `defaultGranted` policy flag per feature** — rejected: it would drift from the
  real safety property. Deriving runtime-eligibility from `secretBearing` + `featureGroups`
  keeps "what a stranger may have" provably tied to "what confers no privilege and no
  secret," with nothing to keep in sync.
- **Keeping `hostName` in `hostFacts` for convenience** — rejected: it is an open
  invitation to identity-branch, the exact coupling the model exists to remove. Excluding
  it is the forcing function that turns the signing-key host-list into a `signing` grant.
- **Modeling "headless" as a gui ban** — rejected: it conflates incapacity with
  prohibition and dilutes the one verb (prohibit) that must carry security weight.
