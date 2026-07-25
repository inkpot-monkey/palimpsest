# web-starter

A static-first [Astro](https://astro.build) site: a vanilla-CSS design-token
system, self-hosted variable fonts, a reproducible Nix dev shell, and a
pre-push quality gate. Deploys to Cloudflare Pages with zero client JS by
default.

> **Note:** the full _how-I-build-websites_ guide — the durable principles
> behind these choices — lands in this README (tracked separately). What follows
> is the mechanical quickstart.

## Quickstart

```sh
direnv allow        # or: nix develop  — enters the dev shell (Node, pnpm, Chromium)
pnpm install
pnpm dev            # http://localhost:4321
```

## Commands

| Command         | What it does                                      |
| --------------- | ------------------------------------------------- |
| `pnpm dev`      | Dev server with HMR                               |
| `pnpm build`    | Static build to `dist/`                           |
| `pnpm preview`  | Serve the built `dist/` locally                   |
| `pnpm check`    | `astro check` + `vitest run`                      |
| `pnpm test`     | Vitest (watch)                                    |
| `pnpm test:e2e` | Playwright (Chromium; a11y + broken-link recipes) |
| `pnpm lint`     | ESLint + Stylelint                                |
| `pnpm format`   | Prettier `--write`                                |
| `nix fmt`       | Format Nix (nixfmt + statix + deadnix)            |

## Layout

```
src/
  layouts/   Layout.astro — <head>, fonts, global CSS
  pages/     routes (index.astro, about.astro)
  lib/       typed content SSOT (site.ts)
  styles/    reset.css, tokens.css, global.css
e2e/         opt-in Playwright recipes (a11y, links)
tests/       vitest unit tests
docs/        agents/ + adr/
```

## Conventions

The rules live in [`CODING_STANDARDS.md`](./CODING_STANDARDS.md);
[`AGENTS.md`](./AGENTS.md) is the operational entrypoint. In short: style through
the tokens in `src/styles/tokens.css`, keep to the lowest rung of the escalation
ladder that works, and let the pre-push gate keep `main` green.

## Deploying (Cloudflare Pages)

- **Build command:** `astro check && vitest run && astro build`
- **Output directory:** `dist`

To add server-rendered routes at the edge, install `@astrojs/cloudflare`, set
`output: 'server'` in `astro.config.mjs`, and record the jump in an ADR.
