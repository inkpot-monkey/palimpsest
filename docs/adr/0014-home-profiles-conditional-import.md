# Home profiles use conditional imports, not the NixOS "import-all + gate" model

The NixOS profile bundle imports every profile and relies on each being a `mkIf`-gated no-op when disabled (see [0013](0013-uniform-bundle-consumption.md)). The per-user home-manager profiles **cannot** follow that model. `porcupineFish` pins `home-manager-25_11` (forced by its Raspberry-Pi kernel toolchain, which pins an older nixpkgs), and the gui/dev/ai/emacs home modules reference home-manager options that don't exist in that release. `lib.mkIf` can't suppress "option does not exist" errors — unknown-option checks run during structural name-collection, *before* the condition is evaluated — so a disabled-but-imported module still aborts evaluation on the old release. Therefore `users/inkpotmonkey/home/profiles.nix` imports those modules **conditionally** (`lib.optionals isGui [...]`) instead of importing-and-gating.

The conditional keys on `isGui` as a pragmatic **proxy** for "this host's home-manager is new enough." That holds only because the single old-home-manager host is also the only cli Pi; a future GUI host on old home-manager, or a cli host needing a version-divergent module, would break the proxy. We accept the proxy — there is no clean eval-time way to ask "does this home-manager know option X" — and document it here rather than fixing it.

## Consequences

- Don't "simplify" the home `lib.optionals isGui` imports into the bundle's import-all pattern — it will break `porcupineFish` (and any future host on a pinned older home-manager).
- "Profile" therefore means two structurally different things: fleet-shared NixOS profiles (import-all) and per-user home profiles (conditional import). See `CONTEXT.md`.
- If the version skew ever ends (all hosts on one home-manager), the home side can converge on the NixOS import-all model and drop the `isGui` keying.
- The host↔user feature model reuses this conditional-import as its escape hatch: features that touch version-divergent home-manager options are imported conditionally rather than token-gated — see [contract ADR-0001](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0001-host-user-contract.md).

## Considered Options

- **Key the conditional on the home-manager version/capability directly** instead of `isGui` — rejected for now: there's no clean way to detect "does this home-manager know option X" at eval time, and the `isGui` coincidence currently holds. Revisit if a GUI host ever lands on a pinned older home-manager.
- See `hosts/porcupineFish/README.md` for the original host-level rationale.
