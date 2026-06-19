# The JMAP↔Matrix bridge lives in its own repo, consumed as a flake input

The bespoke email bridge ([ADR-0007](0007-custom-jmap-matrix-bridge.md)) was developed in-tree under `pkgs/jmap-matrix-bridge/`, with its NixOS service module and VM round-trip check alongside it. It now lives in a standalone public repository, `palebluebytes/jmap-matrix-bridge`, consumed here as the `github:` flake input: the input's overlay supplies `pkgs.jmap-matrix-bridge` fleet-wide, and its `nixosModules.jmap-bridge` is imported by the matrix profile. Only the host-specific glue — sops templates, the tuwunel/identity wiring in `modules/nixos/profiles/matrix/jmap-bridge.nix` — stays in this repo.

The split is clean because the seam already existed: the ~14k-LOC Rust crate has **zero** dependencies on this repo's Nix code, and the service module + VM check are host-agnostic. Git history was preserved on extraction (`git filter-repo`, ~65 commits), so the crate's hard-won regression-test provenance survives.

## Considered Options

- **Keep it in-tree (monorepo)** — rejected: the bridge was 54 of the last 100 commits here, drowning the infra repo's history, and dragging a heavy crane build plus a slow nixosTest round-trip through this repo's `nix flake check` on every change.
- **Vendor the crate but split only the CI** — rejected: doesn't address history churn, and splitting the test from the code it tests is worse than splitting neither.
- **Own repo, consumed as a flake input (chosen)** — the bridge iterates in its own repo with its own CI; this repo pins a known-good rev in `flake.lock` and rebuilds infra without re-testing the bridge.

## Consequences

- A bridge change now requires a commit+push in the bridge repo, then `nix flake update jmap-bridge` here before it deploys — the same two-repo workflow already in force for the `secrets` input ([ADR-0002](0002-secrets-in-separate-stash-repo.md)), so no new mental model.
- The integration point is the single composed overlay (`modules/shared/overlays/default.nix`): it composes `inputs.jmap-bridge.overlays.default`, which is what keeps the service module's `package = pkgs.jmap-matrix-bridge` default resolving on every host. `jmap-bridge.nixpkgs` follows this repo's nixpkgs, so the crate builds against the same pin as the rest of the fleet — deployed bytes are unchanged by the split.
- `crane` is no longer a direct input of this repo (it reaches the build transitively through the bridge input); the bridge was its only consumer.
- The `jmap_bridge` VM check is gone from this repo's `nix flake check`; the round-trip test runs in the bridge repo's CI instead. A change spanning both the crate and the host glue (e.g. a new module option) is now two commits across two repos plus a lock bump — rare, since the glue is stable.
- The repo owner is `palebluebytes` (matching the crate's long-standing `meta.homepage`), distinct from this repo's `inkpot-monkey` GitHub account. It is public, so the input uses the `github:` fetcher (no SSH needed at eval, cache-friendly). It was briefly private at first (consumed via `git+ssh` like the `secrets` input); flipping it public produced a byte-identical build (same store path), so the fetcher swap was a no-op for deployed closures.
