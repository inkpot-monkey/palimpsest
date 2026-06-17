# Every host consumes profiles via the kitchen-sink bundle + enable flags

A host assembles its configuration by importing one kitchen-sink module — `nixosProfiles.bundle`, which pulls in *every* profile (see [0001](0001-flake-parts-custom-namespace.md)) — and then turning features on with `custom.profiles.*.enable`. There is a **single** consumption model across the whole fleet, including the resource-constrained RK1 SBCs.

**Scope: this is about NixOS profiles only.** The per-user *home* profiles deliberately do **not** use this import-all model — they conditionally import version-divergent modules — because of the home-manager version skew across hosts. See [0014](0014-home-profiles-conditional-import.md).

This is deliberate over the obvious-looking alternative of hand-importing only the profiles a host needs. A disabled profile is a `mkIf cfg.enable` no-op, so importing the full bundle contributes **nothing** to the system — it costs only Nix evaluation, which happens on the builder, not the device. The payoff is uniformity and safety: you can never enable a feature whose module you forgot to import, and there is no per-host import list to drift. The RK1 nodes previously imported ~7 profiles à la carte with hand-maintained comments tracking transitive option reads (e.g. `tailscale` reads `custom.profiles.impermanence.enable`); folding them onto the bundle deletes that fragile bookkeeping.

## Consequences

- To give a host a feature, set its `custom.profiles.<name>.enable` — never add a bare `imports` of a profile.
- A profile MUST gate all of its config behind its `enable` flag (`mkIf`). A profile that applies config unconditionally would leak onto every host; that's now a fleet-wide invariant the bundle depends on.
- Verifying behaviour-neutrality of an import change can't use the `toplevel` derivation hash — editing any tracked file changes the `self` flake source, which is baked into `NIX_PATH`/`nix.registry`, so the hash always differs. Compare a config fingerprint instead (package count, etc entries, systemd units, key `enable` flags), which is invariant to the source hash.

## Considered Options

- **Per-host à-la-carte imports** (the RK1 nodes' former approach) — rejected: it adds a manual import list that must track cross-profile option reads, for no closure benefit, since disabled profiles already cost nothing in the built system.
