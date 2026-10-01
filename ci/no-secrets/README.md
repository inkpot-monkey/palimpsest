# `ci/no-secrets` — the stand-in for the private `secrets` input

The `secrets` flake input is a **private** repo (`git+ssh://…/stash.git`), so CI cannot
fetch it. It does not need to: ADR-0012 keeps every `lib.getSecret*` helper falling back
to the checked-in mocks (`parts/mock-secrets.yaml`, `parts/mock-identities.nix`) whenever
a path is absent from that input, precisely so the flake stays eval-able and checkable
without it.

`.github/workflows/checks.yml` therefore runs with

```
--override-input secrets path:./ci/no-secrets
```

which points the input at this directory. Nothing here is read — being an input with no
secret paths in it is the whole job, and every lookup consequently takes the mock branch
and prints the loud `falling back to a MOCK` warning ADR-0012 describes.

This directory exists only because git cannot track an empty one. Do not put anything
real in it, and do not rely on CI to catch a *secret-dependent* regression: by
construction CI never sees a real secret. Deploys stay protected independently —
`sops-install-secrets` fails at activation if a real secret or key is missing (ADR-0002).
