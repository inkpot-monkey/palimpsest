# Secrets live in a separate `stash.git` repo pinned as a flake input

All sops-encrypted secrets live in their own private git repository (`stash.git`), consumed here as the `secrets` flake input (`flake = false`) and resolved via `self.lib.getSecretPath` / `getSecretFile` against `${inputs.secrets}/…`. The secrets are **not** kept in-tree in this public-ish config repo.

We accept a real ergonomic cost for this separation: an edit to a sops file under `secrets/` only changes the stash repo's working tree, so it has **no effect** on builds or deploys until it is committed, pushed, and the input is relocked (`nix flake update secrets`). Deploying before the relock makes `sops-install-secrets` fail at activation because the new key isn't in the locked rev.

## Consequences

- The deploy workflow for any secret change is: `cd secrets && git commit -am … && git push` → `nix flake update secrets` → `just deploy <host>`. Never deploy before relocking.
- The planned host↔user split makes this re-key step *per-feature*: granting a user's feature on a host re-keys that host into the feature's secret — same workflow, finer granularity. See [contract ADR-0001](https://github.com/palebluebytes/host-user-contract/blob/main/docs/adr/0001-host-user-contract.md).

## Considered Options

- Keeping `secrets/` as an ordinary in-tree directory — rejected: it couples secret rotation to this repo's history and weakens the separation between the (shareable) config and the (private) encrypted material.
