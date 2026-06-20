# The platform interface abstracts secret *provisioning*, not just file location

The contract's `platform` interface ([ADR-0015](0015-host-user-contract.md) mechanic 6)
was meant to keep a feature from naming the host's secrets backend. It only half does:
`secretFile name → path` resolves *where the ciphertext lives*, but its shape is
**sops-modeled** — "a named secret group → its encrypted **sops** source file" — and the
features then write `sops.secrets.<n> = { sopsFile = …; key = "restic/repo"; }` and read
`config.sops.secrets.<n>.path` directly. A path-locator plus a key-selector *is* sops's
multi-key-YAML model; agenix is one-age-file-per-secret with no key selector and does not
fit it. So sops is the only backend, and the coupling is in the **interface shape**, not
merely the implementation.

We redesign the `platform` interface to abstract secret **provisioning**: a feature
declares a *logical* secret (a backend-neutral request — a name and its logical id) and
reads a resolved **runtime path**; the host **binding** owns the entire backend mechanism
(a sops YAML + key, or an agenix file). Features stop naming `sops.*` entirely; the host
binding maps logical secrets to `sops.secrets` *or* `age.secrets` and publishes the path
back through the interface. sops is the first and only current binding; **agenix becomes a
drop-in host binding requiring no change to the contract or to any feature module.**

This lands **with the extraction** ([ADR-0020](0020-extract-contract-flake.md)), not after:
publishing the contract with a sops-shaped interface would make backend-agnosticism a
*breaking change* to an already-published interface.

## Considered Options

- **Keep the location-only seam (sops-shaped)** — rejected: it publishes a sops abstraction
  wearing a neutral name; adding agenix later breaks the published interface and every
  feature module that names `sops.*`.
- **Abstract provisioning behind the platform interface (chosen)** — logical secret in,
  runtime path out; the host binding is the only place a backend is named. The contract
  gains no backend dependency; backends are swapped by swapping one host-side binding module.
- **Drop down to a raw specialArg of resolver functions** — rejected for the same reason
  ADR-0015 rejected it for the locator: a typed option set fails loudly when a host forgets
  to bind, an untyped attrset fails late with `attribute missing`.

## Consequences

- **Templates are the one wrinkle.** restic's repo path is built with a sops template
  (`"${config.sops.placeholder.restic_repo}:backups"`); placeholders/templates are sops-nix
  richness agenix lacks natively. The interface either grows a neutral template+placeholder
  seam (mapped per backend) or restic is refactored to compose the repo string at activation
  from the secret file. restic is the *only* template user today, so this is bounded.
- The feature modules that move with the user (`restic`, `signing`) change shape — they
  declare `custom.platform.secrets.<n>` and read a resolved path instead of touching
  `sops.*`. This is behaviour-neutral under the sops binding (same decrypted files at the
  same paths) and is gated by the same byte-identical-fingerprint check as the extraction.
- The host now imports a backend's NixOS module (sops-nix today) and supplies the binding;
  the contract imports neither. A user repo could even choose its own backend, provided the
  host it lands on supplies a matching binding — the interface is the only fixed point.
