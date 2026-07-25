# web-starter — how I build websites

This is a starter scaffold, but it is also an argument. Every choice below is
one I make on every site; the template just carries them, executable, so a new
project starts already pointed the right way. This README is the guide: the
durable principles and _why_ each one earns its place. The prescriptive rules
those principles compile down to live in
[`CODING_STANDARDS.md`](./CODING_STANDARDS.md); the operational entrypoint for
agents is [`AGENTS.md`](./AGENTS.md).

Generate a new site with:

```sh
nix flake init -t github:inkpot-monkey/palimpsest#web-starter
```

Everything is a static [Astro](https://astro.build) site that ships **zero
client JS by default** and deploys to **Cloudflare Pages**.

## Quickstart

```sh
direnv allow        # or: nix develop  — enters the dev shell (Node, pnpm, Chromium)
pnpm install
pnpm dev            # http://localhost:4321
```

The dev shell is defined in [`flake.nix`](./flake.nix); [`.envrc`](./.envrc)
loads it automatically under direnv. You need Nix and (optionally) direnv on the
host — nothing else, no global Node.

## The shape of a site

```
flake.nix          reproducible dev shell + the pre-push quality gate
src/
  layouts/         Layout.astro — <head>, self-hosted fonts, global CSS
  pages/           routes (index.astro, about.astro) with scoped <style>
  lib/             site.ts — typed content, the single source of truth
  styles/          reset.css → tokens.css → global.css
public/            static assets served as-is (favicon.svg)
e2e/               opt-in Playwright recipes (a11y, broken links)
tests/             vitest unit tests (the floor)
docs/              agents/ (tracker) + adr/ (decision records)
CODING_STANDARDS.md   the prescriptive rulebook
AGENTS.md             operational entrypoint
```

## The principles

Each one is a durable stance, a short reason, and the real file that embodies
it. When a rule needs to be enforced rather than explained, it points at
`CODING_STANDARDS.md`.

### 1. Static-first, and escalate reluctantly

A page is HTML until it has a reason not to be. Interactivity is added one rung
at a time, always reaching for the **lowest rung that works**:

1. **Static HTML** — a plain `.astro` page.
2. **Build-time data** — fetch or derive at build, still zero client JS.
3. **Client island** — a scoped `client:*` component shipping the minimum JS.
4. **Edge SSR / Workers** — `@astrojs/cloudflare`, `output: 'server'`, only when
   a request-time concern (auth, personalisation) genuinely demands it.

The default is rung 1: [`astro.config.mjs`](./astro.config.mjs) sets
`output: 'static'`. A jump to rung 3 or 4 is a decision worth recording — see
[`docs/adr/`](./docs/adr/README.md). The full ladder lives in
[`CODING_STANDARDS.md`](./CODING_STANDARDS.md#the-escalation-ladder).

### 2. Astro is the SSG — a deliberate fork

I used to reach for Eleventy + WebC for content sites and Astro for interactive
ones. That fork is retired. **Astro is the single SSG** for everything from a
brochure page to an edge-rendered app, because the one escalation ladder above
spans the whole range without a tooling switch: the same project grows from
static HTML to Workers SSR by changing an adapter, not a framework. Eleventy is
lighter for pure static output, but the moment a site wants an island or an edge
route it becomes a rewrite — so I pay Astro's slightly heavier baseline up front
and never hit that wall. One template, one mental model.

### 3. Content is typed data, not scattered Markdown

The site's content is a typed TypeScript value — [`src/lib/site.ts`](./src/lib/site.ts) —
not front-matter smeared across files. **Define once, derive everywhere:** the
title, description, and nav are declared in one place, and the layout, pages,
and any future feed or sitemap read from it, so they cannot drift. The typed
shape means a wrong field is a build error, not a broken page. Grow this into
per-collection modules as the site grows; the discipline stays the same.

### 4. Vanilla CSS, styled only through tokens

No CSS framework. The entire visual language is three families of design token
in [`src/styles/tokens.css`](./src/styles/tokens.css): **fluid type**, **fluid
space**, and **named colour**. Components reference the _semantic_ tokens
(`--color-fg`, `--step-1`, `--space-m`) and never raw values, so a theme change
— including the built-in dark mode via `prefers-color-scheme` — is a one-line
edit in that file.

- Global element defaults live in [`src/styles/global.css`](./src/styles/global.css)
  (which imports `reset.css` then `tokens.css`).
- Component styles are **scoped** to the component via Astro's `<style>` block —
  see the nav in [`src/pages/index.astro`](./src/pages/index.astro).

The type and space scales are [Utopia](https://utopia.fyi) `clamp()` curves that
interpolate smoothly between a small and a large viewport, so most layouts need
no breakpoints at all.

### 5. Mobile-first, fluid, `min-width` only

Base styles target the smallest screen; enhancements layer **upward** with
`min-width` media queries — **never `max-width`**. Because the tokens already
interpolate small → large, a breakpoint is only for when the _layout itself_
must change (the nav going from a column to a row in `index.astro` is the
canonical example). Breakpoints use `em` so they respect the reader's font size:
`40em`, `60em`, `80em`.

### 6. Self-hosted variable fonts

Fonts are served from your own origin — no third-party request, no layout shift,
no privacy leak. [`src/layouts/Layout.astro`](./src/layouts/Layout.astro) imports
`@fontsource-variable/*` packages (which register their own `@font-face` rules
and ship the woff2 files), and **preloads** the above-the-fold body font by
resolving its woff2 to a hashed URL with Vite's `?url`. Font _roles_
(`--font-body`, `--font-display`, `--font-mono`) are tokens, so swapping a
typeface touches one line.

**Recipe — add a font:**

```sh
pnpm add @fontsource-variable/<name>
```

```astro
// Layout.astro
import '@fontsource-variable/<name>';
// and, only if it paints above the fold, preload it:
import woff2 from '@fontsource-variable/<name>/files/<name>-latin-wght-normal.woff2?url';
// <link rel="preload" href={woff2} as="font" type="font/woff2" crossorigin />
```

Then point a `--font-*` token in `tokens.css` at the new family. For images,
prefer Astro's [`astro:assets`](https://docs.astro.build/en/guides/images/)
`<Image>` over raw `<img>`: it optimises, fingerprints, and sets intrinsic
dimensions at build time.

### 7. Accessibility is the floor, not the ceiling

`:focus-visible` outlines, honoured `prefers-reduced-motion`, real landmarks and
labels — baked into [`global.css`](./src/styles/global.css) and the markup, not
bolted on. The axe recipe in [`e2e/a11y.spec.ts`](./e2e/a11y.spec.ts) fails the
build on `wcag2a/aa` violations; treat it as the minimum bar, not the goal.

### 8. One Nix-native quality gate, all at pre-push

There is a single gate, and it lives in [`flake.nix`](./flake.nix) via
`git-hooks.nix`. **Every hook runs at pre-push; nothing at pre-commit** — so
commits stay fast and local, and the remote stays clean. The chain is
`treefmt → prettier → eslint → stylelint → astro check → vitest`. Prettier owns
everything web (`useTabs`, `prettier-plugin-astro`); `treefmt` owns Nix (nixfmt +
statix + deadnix). The rules are spelled out in
[`CODING_STANDARDS.md`](./CODING_STANDARDS.md#formatting--quality-gates).

### 9. A testing floor that can't be skipped

The always-green floor is `astro check` + `vitest run` + `astro build`. The
scaffold ships one real vitest example — [`tests/site.test.ts`](./tests/site.test.ts) —
exercising the typed content SSOT; replace it, don't delete it. Crucially, the
**Cloudflare build command is `astro check && vitest run && astro build`**, so
even a `git push --no-verify` that skips the pre-push hook still cannot deploy a
red type error or unit test. Browser suites (Playwright, Chromium-only — bundled
browsers don't run on NixOS) run pre-push and add the opt-in a11y and
broken-link recipes in [`e2e/`](./e2e/).

### 10. The dev shell is the environment

[`flake.nix`](./flake.nix) pins Node 24, pnpm, the language servers, and the
Chromium that Playwright drives. `direnv allow` and you have exactly the toolset
CI and I have — no "works on my machine". No global installs, no version drift.

### 11. Commits and docs carry the _why_

Conventional Commits, scoped by feature-folder or domain noun, imperative and
lowercase, with a **why-focused** subject (`feat(nav): trap focus so Esc returns
home`), one self-contained change per commit. Issues live on GitHub via `gh`
([`docs/agents/issue-tracker.md`](./docs/agents/issue-tracker.md)); hard-to-reverse
decisions become ADRs in [`docs/adr/`](./docs/adr/README.md). `AGENTS.md` points;
`CODING_STANDARDS.md` prescribes; neither repeats the other.

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

## Deploying (Cloudflare Pages)

- **Build command:** `astro check && vitest run && astro build`
- **Output directory:** `dist`

To add server-rendered routes at the edge (rung 4), install `@astrojs/cloudflare`,
set `output: 'server'` in [`astro.config.mjs`](./astro.config.mjs), and record
the jump in an ADR.
