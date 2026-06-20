# The host↔user contract lives in its own flake, delivered as a registry-baked kit

[ADR-0015](0015-host-user-contract.md) stood the contract up **in-repo** as a shared
module set on `self.contract`, deliberately framing the eventual repo split as "a URL
change, not a re-wire." The feature-registry refactor (the [ADR-0018](0018-user-confinement-manifest-greeter.md)-review
cleanup) made that real: the contract is now one registry with everything projected
from it, depending on nothing but nixpkgs `lib`. So the contract is extracted into a
standalone **public** flake (`palebluebytes/host-user-contract`, matching the
`jmap-bridge` precedent of [ADR-0017](0017-jmap-bridge-own-repo.md)), consumed here as a
`github:` input with `inputs.nixpkgs.follows = "nixpkgs"`. This is **slice 07a** — the
behaviour-neutral relocation; the heavier user-repo split + request channel stays with
the greeter ([ADR-0018](0018-user-confinement-manifest-greeter.md)) because that work and
the greeter define each other.

The extraction is the litmus test that the host↔user boundary is real: the contract must
evaluate with **no host coupling**, and the whole-fleet config fingerprint (groups,
display flags, insecure permits, safe set) must be **byte-identical** before and after.

## How the kit is delivered

- **Modules close over their own registry (not `self`).** Today `realization.nix` reads
  `self.contract.privilegedGroups` — where `self` is the *consuming host* flake. The
  contract flake instead builds `nixosModules.default` by applying its modules to its own
  registry data, captured from the flake's own scope. The shipped modules drop the `self`
  argument entirely: they read contract data from the closure and host config from
  `config`. The consumer just `imports = [ inputs.contract.nixosModules.default ]`.
  *(Rejected: threading the contract as a `mkSystem` specialArg — every consumer and every
  module would carry the plumbing; and re-exporting `self.contract = inputs.contract…` —
  brittle, leaks the contract into the host's `self`.)*
- **One umbrella kit per eval-side.** `nixosModules.default` (the `custom.users` schema +
  `custom.platform` interface + `custom.host.exposed` + the exposed-host assertion +
  realization + the insecure-package aggregator + feature modules) and
  `homeModules.default` (identity + home-profiles + platform interface). Plus `lib` (the
  contract *functions*) and a data surface (`features`, `featureMeta`, `featureGroups`,
  `privilegedGroups`, `safeSet`) the host reads where it wires grants and recipients.
  À-la-carte modules buy nothing — no host wants the schema without the realization.
- **The contract depends only on nixpkgs `lib`.** The single package-ecosystem coupling —
  the emacs overlay in `features/gui.nix` — is **moved out**: it is inkpotmonkey's package
  choice, not part of the neutral interface, and is reapplied host-side where a gui user
  actually wants it. The contract flake takes no `emacs-overlay` input.
- **`lib` splits along intrinsic-vs-fleet.** The contract flake's `lib` holds
  `runtimeEligibleFeature`, `mkFeatureRecipients` (the *algorithm*), `exposedHostOffenders`,
  `mkHostFacts`; the host keeps the secrets resolvers, `mkPkgs`, `mkSystem`/`mkPiSystem`,
  overlays, the mbsync helpers — and `featureRecipients = mkFeatureRecipients
  self.nixosConfigurations`, the algorithm *applied to this fleet*. Call sites reference
  `inputs.contract.*` **explicitly** (no re-export into `self.lib`): the whole point is to
  make the boundary visible at every use, which a re-export would hide.
- **The conformance suite splits the same way.** The contract flake ships the **generic**
  suite — the matrix (synthetic users × archetypes), grant/deny, and the gui-union VM,
  using only synthetic manifests it defines itself — and gains independent CI (testable
  with no host repo). The host keeps a thin **coherence gate**: every *real* host's
  trait-tuple is covered by an archetype, and the real inkpotmonkey manifest realizes.
- **The platform binding stays host-side.** The contract ships only the typed `platform`
  *interface*; the host supplies the *binding* (`config.custom.platform = …`, which reads
  `inputs.secrets`) via a small host-side module — one per eval-side. That keeps every
  secret path out of the contract, and is a second litmus test: the contract must evaluate
  with the platform *unbound*. The interface itself is made backend-agnostic first — see
  [ADR-0021](0021-platform-backend-agnostic-secrets.md).

## Consequences

- A contract change is a commit+push in the contract repo, then `nix flake update contract`
  here — the same two-repo workflow already in force for `secrets` ([ADR-0002](0002-secrets-in-separate-stash-repo.md))
  and `jmap-bridge` ([ADR-0017](0017-jmap-bridge-own-repo.md)). No new mental model.
- Developed behind a `path:` input for a fast inner loop (no push+relock per change), then
  flipped to `github:` once the fingerprint is byte-identical — literally the "URL change"
  ADR-0015 promised. Public + `github:` means no SSH at eval and a cache-friendly fetch.
- The contract repo holds zero secrets and zero hostnames — pure schema, realization, and
  security model — so it is safe to publish, and being public aligns with the greeter's
  "enter a flake URL" premise: external user repos can reference the same neutral contract.
- This proves the boundary but does **not** yet separate a *user* into its own repo. The
  user-repo split, the `contract.requests` channel, and any re-key ride with the greeter
  ([ADR-0018](0018-user-confinement-manifest-greeter.md)), since the external-user-repo
  shape and the greeter's trust model define each other.
