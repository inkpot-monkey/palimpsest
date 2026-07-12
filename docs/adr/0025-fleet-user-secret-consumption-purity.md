# Fleet infrastructure never depends on a user secret (consumption purity)

The **User** is a portable bundle — public identity, home config, its own secrets,
grantable features — destined to extract into its own repo (the host↔user contract,
contract ADR-0001). Today the **Stash** commingles two ownership classes in one repo:
**fleet secrets** (`profiles/*.yaml`, owned and consumed by the fleet) and **user
secrets** (`users/<name>.yaml`, part of the user bundle). That is fine until a *user*
secret is consumed by *fleet* machinery — then the two are coupled, and extracting the
user silently breaks the fleet.

This was already real, not hypothetical. The `tailscale-dns` operator app and the
`secrets/expiry.nix` monitoring registry both pointed at a Tailscale API key living in
`users/inkpotmonkey.yaml`. That key is user-minted (a personal `tskey-api-…` on the
user's tailnet) but does purely fleet work — it keeps the tailnet's global nameservers
pointed at the fleet's blocky resolvers. Ownership (user) and consumption (fleet)
diverged, so lifting the user out would have stranded fleet DNS management.

## Decision

**Fleet infrastructure — host services, operator apps, and monitoring — must never
depend on a user secret. Anything the fleet consumes lives in a fleet file
(`profiles/*.yaml`) by construction.** This is *consumption purity*: extracting a user
breaks nothing on the fleet because nothing fleet-side reads `users/`.

The invariant is deliberately scoped to the **secret layer**. A user-owned *credential*
that does fleet work is relocated into a fleet file; there is nothing to "cut" at
extraction, so the user bundle stays clean by rule rather than by cleanup.

Concretely, the `tailscale-dns` credential moved from `users/inkpotmonkey.yaml` (key
`tailscale`) to `profiles/networking.yaml` (key `tailscale_dns_api_key`), beside the
fleet's existing `tailscale_key` node-authkey. The app now decrypts from the fleet file,
`expiry.nix` tracks it there, and the user stash no longer holds it.

## Why consumption purity, not an ownership boundary with declared seams

The considered alternative was to *allow* fleet tooling to reference a user secret but
record each reference as a documented "extraction seam" to sever later. Rejected: a rule
with a standing exception is a goal, not an invariant, and the whole point is that the
user's extraction is the seam we do **not** want to discover by hand. Purity makes
extraction a non-event; the ownership boundary makes it a checklist that rots.

## Scope: the secret layer, not the identity layer

Purity here means the fleet holds no *user secret*. It does **not** yet mean the fleet
has a Tailscale identity independent of the user: the tailnet itself is the user's
personal account, so a truly fleet-owned credential (an OAuth client / org tailnet) is a
larger *platform-identity* concern, out of scope for this ADR. Relocating the ciphertext
into a fleet file satisfies the secret-layer invariant today; the identity layer is a
separate future step.

## The staged migration (provenance purity is deferred, with a forced deadline)

The relocated value is still a **personal access token** — user-login-minted, so its
*lifecycle* is user-bound even though its ciphertext is now fleet-owned. That residual is
retired at the token's **forced 90-day rotation (2026-10-05)**: instead of re-minting
another personal token, mint a **fleet-owned OAuth client** (DNS scope), which adds a
token-exchange step to the app and cuts the user-login provenance. The `expiry.nix`
runbook and the app's auth comment both carry this as the rotation instruction, so the
deadline is free — the secret expires exactly when the migration is due.
