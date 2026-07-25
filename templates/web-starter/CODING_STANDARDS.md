# Coding standards

The prescriptive rulebook for this site — the single source of truth for _how_
we build here. A living document: when a convention changes, change it here
first, then the code. [`AGENTS.md`](./AGENTS.md) links here; it does not repeat.

## Stack & altitude

- **Astro, static-first.** `output: 'static'` → Cloudflare Pages, zero client JS
  by default. Content is typed TS/JSON as a single source of truth ("define
  once / derive both"), not Markdown front-matter scattered across files.
- **Vanilla CSS, no framework.** Style only through the design tokens in
  `src/styles/tokens.css` (fluid type/space + named colours). Components own
  their styles via Astro's scoped `<style>`; global rules live in
  `src/styles/global.css`.
- **Mobile-first, always.** Write the base styles for the smallest screen, then
  layer enhancements upward with `min-width` media queries only — **never
  `max-width`**. The fluid type/space tokens already interpolate small → large,
  so most layouts need no breakpoints at all; reach for one only when the layout
  itself must change. Use `em` breakpoints (they respect the user's font size):
  `40em`, `60em`, `80em`.
- **Accessibility is not optional.** `:focus-visible` outlines, honoured
  `prefers-reduced-motion`, real landmarks and labels. The a11y e2e recipe is
  the floor, not the ceiling.

## The escalation ladder

Reach for the **lowest rung that works**; document a jump to rung 3 or 4 in an
ADR.

1. **Static HTML** — plain `.astro` pages.
2. **Build-time data** — fetch/derive at build, still zero client JS.
3. **Client island** — a scoped interactive component (`client:*`) shipping the
   minimum JS.
4. **Edge SSR / Workers** — add `@astrojs/cloudflare`, switch `output` to
   `'server'`. Only when a request-time concern (auth, personalisation) demands
   it.

## Formatting & quality gates

One Nix-native gate. **All hooks run at pre-push; none at pre-commit** — commits
stay fast, the remote stays clean.

- **Formatting** — Prettier owns TS/JS/JSON/CSS/Astro/Markdown (`.prettierrc`:
  `useTabs`, `prettier-plugin-astro`; no `.editorconfig`). `treefmt` owns Nix
  (`nixfmt` + `statix` + `deadnix`). Run: `pnpm format` and `nix fmt`.
- **Linting** — ESLint (flat config, type-aware `typescript-eslint` +
  `eslint-plugin-astro` + `eslint-config-prettier`) and Stylelint
  (`stylelint-config-standard`).
- **Pre-push chain** (order): `treefmt --fail-on-change` → `prettier --check` →
  `eslint` → `stylelint` → `astro check` → `vitest run`. Wired in `flake.nix`
  via `git-hooks.nix`; installed by the dev shell.
- **Deploy backstop** — the Cloudflare build command is
  `astro check && vitest run && astro build`, so a `--no-verify` push still
  can't ship a red type error or unit test.

## Testing baseline

- **Floor (always green):** `astro check` + `vitest run` + `astro build`. Ship
  at least one real `vitest` test (see `tests/`); unit tests use `happy-dom` and
  Astro's `getViteConfig` so they resolve imports exactly like the site.
- **Browser (Playwright):** Chromium-only — bundled browsers don't run on NixOS,
  so the dev shell provides `pkgs.chromium` and the config resolves it via
  `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`. Two projects: **Desktop Chrome
  1920×1080** and **Mobile Chrome (Pixel 5)**. Browser suites run pre-push, not
  in the deploy floor.
- **Blessed opt-in recipes** (`e2e/`): **axe** accessibility
  (`@axe-core/playwright`, `wcag2a/aa` + `wcag21a/aa`) and a **broken-link**
  check. Visual-regression, SEO assertions, and Lighthouse budgets are left to
  each site to add as needed.

## Commits

Conventional Commits, scoped by feature-folder or domain noun, imperative and
lowercase, with a **why-focused** subject. One self-contained change per commit.
