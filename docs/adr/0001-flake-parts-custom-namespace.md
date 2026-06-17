# flake-parts layout with a `custom.*` option namespace

The fleet is built with `flake-parts`, splitting the flake into composable modules under `parts/`, `hosts/`, `modules/`, `users/`, and `lib/` rather than one monolithic `flake.nix`. All first-party configuration is exposed under a single `custom.*` option namespace, and per-host behaviour is selected by toggling **profiles** (feature bundles under `modules/nixos/profiles/`) rather than by importing modules ad hoc.

We deliberately distinguish two kinds of module: a **profile** only toggles and configures existing functionality (`custom.profiles.*`), whereas a **service module** under `modules/nixos/services/` packages and runs a bespoke long-running program. Keeping that line sharp is what lets hosts be assembled declaratively from a small vocabulary of enable-flags.

## Consequences

- New functionality should be added as a profile or service under `modules/`, wired through a `custom.*` option — not inlined into a host's `configuration.nix`.
- The `custom.*` namespace is load-bearing API: renaming options is a fleet-wide change.
