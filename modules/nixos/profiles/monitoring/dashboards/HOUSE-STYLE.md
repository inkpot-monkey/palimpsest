# Grafana dashboard house style

The single style every board in this directory conforms to. Boards are committed
as JSON here and provisioned read-only onto rk1b's Grafana from the Nix store;
edit them against the live preview loop (`just grafana-preview`), never in the
deployed instance.

**Reference board:** [`_house-style-sample.json`](./_house-style-sample.json)
("House Style — Sample Panels") renders every rule below against rk1b's real
data. When a rule is ambiguous, copy the matching panel from there. It is
**preview-only** — deliberately absent from `server.nix`'s dashboard allowlist,
so it renders in `just grafana-preview` but never ships to rk1b. Keep it that
way.

The palette is the Claude Code `dataviz` skill's reference palette, pinned to
exact hexes. It was chosen by running that skill's `validate_palette.js` against
**both** Grafana surfaces — see [Palette](#palette).

______________________________________________________________________

## Palette

Colours are **pinned to exact hexes**, applied as fixed values in panel JSON.
This is deliberate: it is the strongest consistency guarantee and it is
colour-blind-safe by construction (validated, not eyeballed).

### Why one fixed hex per role (the light/dark decision)

Grafana cannot theme a raw hex — one value renders in **both** the dark and
light Grafana themes. So each role gets a single hex that must clear both
surfaces. We validated the `dataviz` palette's two candidate columns with
`scripts/validate_palette.js`:

| Candidate column | Dark surface `#1a1a19` | Light surface `#ffffff` |
|---|---|---|
| **dark column** | PASS | **PASS** |
| light column | FAIL (lightness + violet contrast) | PASS |

The **dark column is the only set that passes both**, so the house style uses
the dataviz **dark-column** categorical hexes as the single fixed value. Dark is
the primary target (rk1b and the preview loop default to it); light is a
first-class fallback that these values also satisfy.

Re-run before changing any colour:

```
node .claude/…/dataviz/scripts/validate_palette.js "<hex,hex,…>" --mode dark  --surface '#1a1a19'
node .claude/…/dataviz/scripts/validate_palette.js "<hex,hex,…>" --mode light --surface '#ffffff'
```

### Status colours (reserved — never used for a series)

Health/state signal. These four are the glance vocabulary; a status colour never
doubles as "series N", and always ships with a text/value mapping (never colour
alone).

| Role | Hex | Use |
|---|---|---|
| good | `#0ca30c` | up / OK / in-sync / healthy headroom |
| warning | `#fab219` | first band worth a look (≥80% used, elevated latency) |
| serious | `#ec835a` | escalated but not down (age ≤7d) |
| critical | `#d03b3b` | down / FAIL / ≥90% used / expiring ≤3d |

`dark-red` (`#8f1a1a`) is available for the "past the floor" step in a
multi-band ramp (see the age ramp) but is not one of the four reserved roles.

### Categorical series (fixed order, never cycled)

Assign in slot order to enumerable entities (hosts, alignment types, sender
domains). **Colour follows the entity, not its rank** — pin each entity with a
`byName` field override so a filter never repaints the survivors. Never let
Grafana hash names to colours when the set is small and known.

| Slot | Hue | Hex | Slot | Hue | Hex |
|---|---|---|---|---|---|
| 1 | blue | `#3987e5` | 5 | violet | `#9085e9` |
| 2 | aqua | `#199e70` | 6 | red | `#e66767` |
| 3 | yellow | `#c98500` | 7 | magenta | `#d55181` |
| 4 | green | `#008300` | 8 | orange | `#d95926` |

- A 9th series is never a new hue — fold into "Other", small-multiple it, or
  drop the cardinality.
- Worst adjacent CVD ΔE is 10.3 (the 8–12 floor band), so identity must never be
  colour-alone: a `timeseries` **always** carries a legend, and tables/labels
  name the entity. That secondary encoding is what makes the floor-band legal.
- For **unbounded/unknown** series where per-entity pinning is impractical, fall
  back to `palette-classic` and say so in the panel description — but prefer to
  reduce cardinality first.

### Chrome

Lean on Grafana's own theme for surfaces, gridlines, and text ink — do **not**
override them. Fixed hexes are for status and categorical marks only.

______________________________________________________________________

## Threshold bands

Absolute thresholds, status hexes, for the recurring metric shapes. `min`/`max`
are set so the colour and any bargauge fill are meaningful.

| Shape | Unit | Bands |
|---|---|---|
| **%-used** (disk, memory) | `percent`, min 0 max 100 | good `<80` · warning `≥80` · critical `≥90` |
| **up / down** | `none`, value-mapped | critical at `null` · good at `1` (mapping: `0→DOWN/FAIL`, `1→UP/OK`) |
| **count of a bad thing** (drift, non-compliant) | `none` | good at `null` · warning/critical at the first/second count that matters (e.g. drift good→critical at `2`) |
| **age-in-days remaining** (secret expiry) | `d` | non-linear, soonest-first: critical `≤3` · serious `≤7` · warning `≤14` · soft-amber `#e8c766` `≤30` · good above |
| **latency** | `s` | good below · warning line at a soft SLO (e.g. `1`) · critical at the hard one (e.g. `3`) |

The age ramp keeps **four** live bands plus good (approved in review) — it stays
green until a key nears expiry, then ramps sharply so the eye is only drawn when
action is near.

______________________________________________________________________

## Panel-form decision rules

Pick the form by the data's job, not habit. **`graph` is retired — always
`timeseries`.**

| The data's job | Form | Notes |
|---|---|---|
| One headline number / a single state | `stat` | KPI tiles, "is everything OK" glance. `colorMode: background` for a **state** you want to shout; `colorMode: value` for a **count** where only the number colours. |
| Per-entity state at a glance (N small tiles) | `stat` (multi-series) | one tile per host/endpoint, `background`, value-mapped. |
| Change over time | `timeseries` | trends, rates, latency. Never a `graph`. |
| Magnitude compared across a **small, bounded** set | `bargauge` | %-used per host/mount, ranked bars. `displayMode: gradient`. |
| Per-entity detail, many columns, mixed units | `table` | one row per entity; unit/threshold set per-column via `byName` overrides. |

Do **not** use a dual-axis chart. Two measures of different scale → two panels.

______________________________________________________________________

## Naming & units

- **Board title:** Title Case, no "dashboard" suffix — `Fleet Overview`,
  `DMARC`, not `dmarc dashboard`. `uid` is the kebab-case slug.
- **Panel title:** sentence case, terse — `Disk usage %`, `Config drift`,
  `Probe latency`. Keep the metric's shape in the name.
- **Description:** every panel has one. State the query's meaning, the threshold
  cutoffs, and any gotcha (why a host reads down, when a panel is empty).
- **Units:** use Grafana's semantic unit, never bake units into the title text.
  `percent` (0–100) for a computed %; `percentunit` (0–1) only when the metric is
  natively 0–1. `bytes`, `s` (durations), `d` (age-in-days), `none` for counts.
- **Decimals:** `0` for counts and %-used; `2` for load / latency; let ratios
  pick their own.
- **Tags:** every board tagged for its area (`fleet`, `nixos`, `mail`, `logs`, …).

______________________________________________________________________

## Layout grid

24-column grid. The layout answers "is everything OK?" top-left, then descends
into detail.

- **Top-left = the glance.** A row of KPI `stat` tiles, `h: 4`, spanning the top
  (`8`-wide thirds, or a full-width `24` state strip below them). A viewer must
  read overall health without scrolling.
- **Magnitude / trend band:** `bargauge` and `timeseries` at `w: 12, h: 7–8`
  (two across), or `24` for a single wide series.
- **Detail at the bottom:** `table` and per-entity `stat` strips full-width
  (`w: 24`).
- Use `row` panels to label bands on longer boards.
- `graphTooltip: 1` (shared crosshair) so time-aligned panels move together.
- Board defaults: `timezone: browser`, a sensible `time.from` for the board's
  cadence (`now-6h` fleet, `now-30d` reporting), `schemaVersion: 39`.

______________________________________________________________________

## Datasource variable (the one encoded concession)

Every board carries a datasource **template variable** and references it in every
panel and target, so a board is never pinned to one Grafana's datasource UID:

```json
"templating": { "list": [
  { "name": "datasource", "label": "Data source", "type": "datasource",
    "query": "prometheus", "refresh": 1, "hide": 0,
    "current": {}, "options": [], "regex": "", "multi": false, "includeAll": false }
] }
```

- Reference it everywhere as `{ "type": "prometheus", "uid": "${datasource}" }` —
  on the panel **and** on each target.
- A logs board adds a second variable `logs_datasource` with
  `query: "victoriametrics-logs-datasource"`, referenced the same way.

______________________________________________________________________

## Commit hygiene

Editing in the preview UI stamps a **board-level** `id` and bumps `version` on
export. The in-tree convention is `id: null` and `version: null` — reset both
before committing (`git diff` flags them). Panels keep their own integer `id`.
See `preview.sh` for the full export gotcha.
