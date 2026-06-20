# Host-affecting feature configuration aggregates across granted users (the gui-session union)

The realization owns host-wide singletons so users don't fight over them (ADR-0015
mechanic 5). But a user still has host-*affecting* preferences — most visibly, a
gui user wants a **Wayland** session or an **X11** session. weedySeadragon makes
this concrete: `inkpotmonkey` (Wayland) and `eyeofalligator` (X11) both log in, and
each had written a raw, conflicting `services.xserver.enable` (false vs true), so
the host did not evaluate at all.

The decision: such a preference is **feature configuration** — user-owned
*parameters* of a feature, distinct from the host's **grant** (its yes/no) — and the
realization **aggregates** it across all *granted* users as a **union**. It neither
lets a user set the host singleton directly, nor forces one value, nor (yet)
confines the user. A gui user declares `gui.session = "wayland" | "x11"`; the
realization enables Wayland iff some granted gui user wants Wayland, and
`services.xserver` iff some granted gui user wants X11 — both when both.

The justification is **single seat**: a workstation has one physical display, so two
users never drive it simultaneously. The host can therefore offer the *union* of
session types and each user logs into their own — stock SDDM lists both and
remembers each user's choice per-user (no custom greeter; the contract just installs
both session files). The "conflict" was an artifact of users writing raw host
options; modeled as a union of user-owned preferences, it dissolves.

This generalizes: a feature's configuration splits into **user-scoped** parameters
(applied per user) and **host-affecting** parameters (aggregated across granted
users). The gui session is the first host-affecting case; fonts and input methods
union the same way.

## Consequences

- A user declares `gui.session`, **never** `services.xserver.enable`. The display
  surface is *derived* from the union of granted users' sessions — adding/removing a
  user changes it automatically.
- **Feature configuration is first-class, distinct from the grant** (see `CONTEXT.md`).
  The realization reads a feature's configuration only when the feature is granted.
- Aggregation only fits parameters that genuinely **union**. A truly singular
  setting (system timezone, kernel) cannot be a per-user feature parameter — it stays
  a host decision. Do not model singular settings as feature configuration.
- Under the current trust model (A), this is enforced only by **hygiene**: nothing
  stops a user module from writing the raw `services.xserver.enable` again and
  re-breaking the union. Making it impossible is the **restricted-`evalModules`
  boundary (model C, ADR-0015 mechanic 7)**, deferred — see the model-C meta issue.
- The conformance suite proves it at two levels. At eval
  (`parts/checks/host-user-contract`): two fixture users with different `gui.session`
  on one host ⇒ the host enables *both* session types and both accounts are intact;
  a Wayland-only host enables only the Wayland greeter and an X11-only host only X11
  (the surface is *derived*, not constant). At runtime
  (`parts/checks/host-user-contract-vm`, a `runNixOSTest` boot): the same two-session
  host comes up with both a plasma Wayland *and* a plasma X11 session file live and
  both user accounts activated — the coexistence claim observed on a real machine.

## Considered Options

- **The host decides the display server** — rejected: it loses a user's exact
  config. Forcing Wayland drops eyeofalligator's X11; forcing X11 drops inkpotmonkey's
  Wayland. The point is that each keeps *their* session.
- **Confine users so the conflict is impossible (model C)** — deferred, not rejected
  (ADR-0015 mechanic 7 / the model-C meta issue). It is the stronger, bypass-proof
  guarantee, but a large curated-catalog commitment; the union delivers coexistence
  now without it, and for a single-author fleet the residual foot-gun is review-stage.
- **Let users set the host singleton with priorities** (`mkForce`/`mkDefault`) —
  rejected: two `mkDefault`s of different values still conflict, and `mkForce` merely
  picks a winner, *silently dropping* the other user's choice. That is the
  weedySeadragon bug papered over, not fixed.
