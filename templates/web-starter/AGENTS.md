# AGENTS.md

Operational entrypoint for agents (and humans) working in this repo. This file
points; it does not duplicate. The prescriptive rulebook is
[`CODING_STANDARDS.md`](./CODING_STANDARDS.md) — read it before changing code.

## Getting started

```sh
direnv allow        # or: nix develop
pnpm install
pnpm dev            # http://localhost:4321
```

## The quality gate

Everything runs at **pre-push** (nothing at pre-commit). To run it by hand:

```sh
nix fmt                     # treefmt: nixfmt + statix + deadnix (Nix files)
pnpm format                 # prettier --write (everything else)
pnpm lint                   # eslint + stylelint
pnpm check                  # astro check + vitest run
pnpm test:e2e               # Playwright (needs the dev shell's Chromium)
```

The Cloudflare Pages build command is `astro check && vitest run && astro build`
— a red type error or unit test can't deploy, even behind `--no-verify`.

See [`CODING_STANDARDS.md`](./CODING_STANDARDS.md) for the rules these commands
enforce and the escalation ladder for adding interactivity.

## Docs & conventions

- **Domain / architecture decisions:** `docs/adr/` (see `docs/adr/README.md`).
- **Issue tracker:** GitHub issues via the `gh` CLI — see
  [`docs/agents/issue-tracker.md`](./docs/agents/issue-tracker.md).
- **Commits:** Conventional Commits, scoped by feature-folder or domain noun,
  with a why-focused subject (e.g. `feat(nav): trap focus so Esc returns home`).
