# `gui-contract-package` fixture

Pre-built binding artifact (ADR-0016 `contractPackage`) for the **gui-granted** external home
(`inkpotmonkey` modules built for the throwaway test identity, `gui`+`signing` granted). Consumed
by `../../gui-eval.nix` to prove the fleet's `bindContractPackage` grant/variant coupling assert
**accepts** this variant — a pure-eval read of `contract-requests.json`, no VM boot.

## Why a committed fixture (not `inputs.users.packages.…contractPackage-gui-test`)

This models production faithfully: a host consumes the pre-built manifest as **published DATA** and
never re-evaluates the home. The fleet pins `users.inputs.nixpkgs.follows = "nixpkgs"` (one nixpkgs
fleet-wide), so forcing it to *re-evaluate* the gui/ai home would build it under the fleet's older
nixpkgs — where the ai slice's `antigravity-ide` (a users-pin-only rename of `antigravity`) is an
undefined variable. The users repo owns that newer pin and proves the home actually realizes
(`users` flake check `full-home-build` + package `contractPackage-gui-test`); the fleet only proves
its binding accepts the resulting manifest. Snapshotting the real manifest here keeps both sides
honest without coupling the fleet's eval to the users repo's nixpkgs.

## Regenerating

`contract-requests.json` is a verbatim snapshot of the real gui contractPackage's manifest, with
object keys sorted (`jq -S`) for stable diffs — the `packages` array keeps its build order (and its
duplicates). Regenerate it whenever the gui home's package set / requests / granted variant changes:

```sh
cd ~/code/users
p=$(nix build --no-write-lock-file \
  --override-input contract path:/…/host-user-contract \
  .#packages.x86_64-linux.contractPackage-gui-test --no-link --print-out-paths)
jq -S . "$p/contract-requests.json" \
  > ~/code/nixos/parts/checks/prebuilt-bind-external/fixtures/gui-contract-package/contract-requests.json
```

`activate` is an inert stub — the pure-eval proof never executes it.
