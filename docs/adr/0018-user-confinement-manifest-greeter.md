# A user is a home-manager module: requests, feature modules, and the anyHost greeter

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

**A user is a home-manager module; every host effect it wants is a *request* the host
grants, never a write the user performs.**

- **The user surface is a single home-manager module — everything is contained there.**
  Its identity, its dotfiles, which contract features it enables, and the host-affecting
  parameters those features need. We choose home-manager as the surface deliberately: it
  is *already* a restricted `evalModules` universe (a home config physically cannot write
  system state), it is *already* the portable standalone artifact the greeter will fetch
  (`flake.homeConfigurations`), and the user's center of gravity (shell, editor, git,
  packages) already lives there. The confinement we need is a property home-manager
  already has — so we take it rather than rebuild it.
- **Features are contract-owned home-manager modules the user *enables*, not authors.**
  Enabling `contract.features.gui` brings the user's gui dotfiles *and* populates a
  read-only **`contract.requests`** namespace — declarative data describing what this
  user wants of the host, *including host-affecting params*:

  ```nix
  contract.features.gui.enable  = true;
  contract.features.gui.session = "x11";          # host-affecting request (inert)
  contract.features.gui.kanata  = ./kanata.kbd;    # host-affecting request (see payload safety)
  # ⇒ config…contract.requests.gui = { session = "x11"; kanata = …; }
  ```
- **The host reads requests and lifts the granted ones; request ≠ write.** A contract-owned
  **system integration** harvests each user's `contract.requests`, and for the features the
  host **granted** applies them at the system level — aggregating host-affecting ones (the
  gui-session union reads *every* granted user's request). The home config only *asks*; the
  system decides and writes, only on grant. So even though a request *names* a host effect
  (`session = "x11"`), the user never performs it — confinement is intact because the user
  populates a data namespace inside home-manager's sandbox, nothing more.
- **Enforcement is structural, plus ignore-overreach / validate-intent.** The user has no
  system channel: it cannot write `users.users`, `nixpkgs.*`, `boot.*`, `sops.*` — those
  are not in home-manager's universe. The contract reads only the typed `contract.requests`
  it understands; an unknown request key is *ignored* (the lenient "build still happens"
  posture), but a *malformed known* request (wrong-typed `session`, misspelled feature
  param) *errors*, because the schema is the user's typo-net. There is **no curated
  system-option catalog** — model C's old headline cost ([ADR-0015](0015-host-user-contract.md)
  mechanic 7) dissolves: home knobs ride home-manager directly (no re-exposure), system
  effects ride contract feature modules the user never touches, and the only schema is the
  per-feature request shape, which the model needs regardless.

This closes three leaks present in the in-tree "model A" posture today:

1. **The clamp bypass.** The slice-04 clamp filters `identity.extraGroups`, but
   `users/inkpotmonkey/nixos/default.nix` writes `users.users.inkpotmonkey.extraGroups`
   *directly* with `disk`, `qemu-libvirtd`, `libvirtd` — privileged groups — which
   list-merge in past the clamp. A home-manager config has no `users.users` to write.
2. **The self-grant.** The `gui` variant sets
   `custom.users.inkpotmonkey.granted.gui.enable = true` — a user module granting its
   own feature. `granted.*` is **host-write-only**; a request can offer gui, never grant it.
3. **The raw-`osConfig` read.** The home module reads the entire system config tree to
   adapt; it should see only a restricted projection (below).

## The grant is the sole enabler; degradation is silent

The host must grant **every** host effect, no exceptions. A user can never *enable* a
feature — only *request* one. A request without a grant is **inert**: the system
integration applies it only `mkIf granted`, so requesting an ungranted feature is never an
eval error — it simply produces a host without that feature, and the build succeeds.
Offers are **implicit** (a user emitting `contract.requests.gui.*` is offering gui); no
formal `offers` field is introduced until the separate-repo future makes "what is on this
user's menu?" un-answerable by inspection.

## Host-awareness is read-only, through a restricted `hostFacts` projection

A user's emitted *requests* are host-independent, but its home module legitimately
**adapts** to the host (today `git.nix` falls back when the signing key is absent). That
adaptation is **read-only** and flows through a contract-defined projection — never raw
`osConfig`:

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
confers no privileged group, bears no secret, **and its request payload is inert**:

```
runtimeEligible(f)  ⟺  ¬featureMeta.f.secretBearing  ∧  featureGroups.f == []  ∧  inertPayload(f)
```

The first two inputs already exist (`privilegedGroups`/`featureGroups`, `secretBearing`).
The third is what the **request model surfaces**: a request payload the host *executes with
privilege* (a `kanata-with-cmd` keymap, whose `cmd` action runs arbitrary shell as the
service) is a code-exec vector — honoring it for a runtime/greeter user hands a stranger a
root shell via a keymap. So a feature carrying such a payload is **not** runtime-eligible.
This is met *structurally*, not by a flag: safe-set features expose only **inert** request
params (the `session` enum and the like), and any payload the host executes —
keyboard-remapping-with-`cmd`, a user-supplied unit — is split into its own
**build-time-only** feature, exactly like the virtualization split below. With that
discipline the hinge falls out with no new trust knob:

> **Privilege is build-time-only. The runtime greeter confers only the safe set — a
> stranger off a flake URL gets a desktop and their own home, and can *never* obtain
> docker/wheel/secrets/signing, nor run code via a request payload.**

This forces two cleanups we need regardless. For gui to be in the safe set: (1) it must
confer only non-privileged groups (`input`, `uinput`, `video`, `plugdev`, `dialout`); the
virtualization groups (`disk`, `libvirtd`, `qemu-libvirtd`, `kvm`) that leaked into the gui
block become their own **default-denied, build-time-only** feature; and (2) its request
payload must be inert — the `kanata-with-cmd` keymap becomes a separate build-time-only
keyboard-remap feature, leaving gui carrying only the inert `session` request. The model
turns leak #1 into a structural boundary and makes the code-exec surface explicit.

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
- **`manyHost` / `manyUser` become one mechanism.** A user's home-manager config (its
  emitted requests) evaluated against a host's explicit grant surface is simultaneously the
  *assembly* (it produces a `nixosConfiguration`), the *conformance matrix* (every pairing
  is an eval to assert over), and the *enforcement* (the user can contribute nothing the
  host did not grant). Today's `hosts/default.nix` shifts from implicit
  *grant-by-which-module-you-import* to explicit *grant-as-data*.
- **Data flow inverts for host-affecting requests.** Today the home reads the system
  (`osConfig`); here the *system integration reads each user's home evaluation* to harvest
  `contract.requests`, and the gui-session union reads *every* granted user's request to
  aggregate. There is no eval cycle because grants are independent host-authored data that
  the request never feeds back into. This is the deliberate cost of a single contained user
  surface; it is paid in the integration layer, not the user's.
- **Migrating a host effect is mechanical**: every write in a user's `nixos/` module is
  relocated into a contract feature module that interprets a `contract.requests` field.
  Because the user has no system channel (above), this does **not** grow a curated catalog
  of user-facing system options — the only schema is the per-feature request shape. Home
  knobs stay in home-manager, so [0014](0014-home-profiles-conditional-import.md)'s
  home-manager version skew is confined to the home side as today — though, since the user
  surface *is* home-manager, the contract's feature modules pin the **host's** home-manager
  ([ADR-0015](0015-host-user-contract.md) mechanic 4's one-nixpkgs/`follows`) to keep that
  skew at the dotfile edge rather than the contract edge.
- **`permittedInsecurePackages` and overlays move host-ward.** A user can no longer relax
  a host-wide security gate; if a granted feature needs an insecure package or an overlay,
  the *feature module* declares it and the host's grant is its acceptance.

## Known knots, and the staged cut that keeps the prototype honest

This model has three places where it twists to make a thing fit. Naming them, and what we
defer:

1. **kanata as a user feature** — the worst fit. kanata remaps a *physical* keyboard on a
   *particular* machine and runs privileged code (`cmd`); forcing it to be a portable,
   greeter-safe user feature is what produced the whole inert-payload clause for one
   service. **Cut:** kanata moves to the **host** for the prototype (issue 11), and "kanata
   as a portable user feature" is deferred (issue 18). The inert-payload *rule* stays in
   the model for when an executable request genuinely arises, but no near-term feature
   needs it — gui becomes cleanly safe-set.
2. **The data-flow inversion** — pushing host-affecting params (`gui.session`) into the
   home-manager request channel means the *system* must read every granted user's home
   evaluation to aggregate (the union). It is the price of one contained surface, and it is
   the main *mechanical* risk. The escape hatch, if it bites: keep host-affecting params
   operator-authored system-side (grant data), and let the home-manager surface carry only
   user-domain config — the gui-session union already works that way today (ADR-0016), so
   the prototype can start there and adopt session-as-request later.
3. **home-manager version skew on the critical path** — because the user surface *is*
   home-manager, ADR-0014's skew (e.g. `porcupineFish`) is central, not an edge.
   Mitigation: the contract's feature modules pin the *host's* home-manager; the prototype
   starts on hosts that share one HM and defers the multi-HM case.

The discipline this implies: **prototype on a real workstation with gui-as-request (inert
params only) + grant-as-data, kanata host-side, no greeter, no full matrix** — prove the
confined request→grant→lift loop end-to-end on one host before generalizing. None of the
deferrals are load-bearing for the others.

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

- **Restricted `evalModules` over a curated system catalog** ([ADR-0015](0015-host-user-contract.md)
  mechanic 7's original framing) — superseded by the request-channel enforcement above.
  Giving the user a single module evaluation against a hand-curated set of re-exposed system
  options would *error* on out-of-catalog writes (tensioning with "build still happens")
  and would carry a perpetual catalog-maintenance cost. Emitting typed requests from a
  home-manager config achieves the same confinement with ignore-semantics and no catalog.
- **Two user surfaces — system-side `featureConfig` data + a separate home module** (this
  ADR's own first draft) — rejected in favor of a *single* home-manager surface that emits
  requests. Two surfaces forced host-affecting params (`gui.session`) to live system-side,
  splitting "the user" across `custom.users.<u>` data and a home module. Folding everything
  into one home-manager config — including the host-affecting requests — is simpler for the
  user, aligns the portable artifact with what the greeter fetches (`homeConfigurations`),
  and gets confinement from home-manager's existing restricted universe. The cost is the
  data-flow inversion (the system reads the home eval) and leaning harder on home-manager
  version skew — both judged worth a single contained surface.
- **Allowlist assertion (keep model A, lint the option-paths a user contributes)** —
  rejected as the *boundary*: it is a post-hoc check over an already-merged evaluation, so
  it is approximate and races the very merges it polices. It can be a transitional
  *backstop* during migration, but not the guarantee.
- **A manual `defaultGranted` policy flag per feature** — rejected: it would drift from the
  real safety property. Deriving runtime-eligibility from `secretBearing` + `featureGroups`
  keeps "what a stranger may have" provably tied to "what confers no privilege and no
  secret," with nothing to keep in sync.
- **Keeping `hostName` in `hostFacts` for convenience** — rejected: it is an open
  invitation to identity-branch, the exact coupling the model exists to remove. Excluding
  it is the forcing function that turns the signing-key host-list into a `signing` grant.
- **Modeling "headless" as a gui ban** — rejected: it conflates incapacity with
  prohibition and dilutes the one verb (prohibit) that must carry security weight.
