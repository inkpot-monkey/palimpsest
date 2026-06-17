# Secret helpers fall back to mocks so the flake evaluates standalone

The `lib.getSecret*` helpers (and `parts/settings.nix`'s node metadata) fall back to checked-in mock files (`parts/mock-secrets.yaml`, `parts/mock-identities.nix`) and placeholder IPs whenever a path is absent from the `secrets` input. The effect is that the whole flake evaluates and `nix flake check`s **without** the private `stash` repo present — so this public repo stays cloneable and eval-able by anyone, and a fresh checkout works before `secrets` is wired.

This was originally added to support **Garnix CI**, which has since shut down. We deliberately **kept** the mechanism anyway: its cost is ~zero (it's passive), it preserves public/offline eval-ability, and it's ready if a successor CI is ever pointed at `nix flake check`. The one real downside — a missing secret silently resolving to a mock — is mitigated by making every fallback **loud**: the `getSecret*` helpers wrap their fallback in `lib.warn` (`warnMock`), and `settings.nix`'s `getMeta` likewise warns when a node's metadata is absent and a placeholder IP is used. So an accidental mock/placeholder substitution during a real build is visible rather than silent. (Deploys are independently protected: `sops-install-secrets` fails at activation if the real secret/key is missing — see [0002](0002-secrets-in-separate-stash-repo.md).)

## Consequences

- A mock fallback now prints `secrets: '<path>' … falling back to a MOCK` at eval time. Seeing that warning during your own build means a secret is missing or mis-pathed — treat it as an error, not noise.
- "CI-able against mocks" is no longer a live goal, just a retained capability; don't invest in keeping checks green against the mock set unless CI is revived.

## Considered Options

- **Rip the fallbacks out and fail loudly on any missing secret** — rejected: loses public/offline eval-ability and is churn across every helper, for a downside that the `lib.warn` already neutralises.
