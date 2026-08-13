# NixOS packaging approach for the `inkpot-monkey/supernote` fork

> **Partly superseded (2026-08-13, [#112](https://github.com/inkpot-monkey/palimpsest/issues/112)).**
> The packaging *approach* this doc chose — nixpkgs `buildPythonApplication`, hand-written
> `dependencies`, local stubs for what nixpkgs lacks — still stands and is still what
> `pkgs/supernote` does. What changed is the subject: the transport is now UPSTREAM
> `allenporter/supernote` at a pinned rev, not this fork, and the dependency closure below is
> stale (upstream adds `python-socketio` and `ical`, and needs `mcp>=2.0.0`, which nixpkgs does
> not have — see `pkgs/supernote/mcp2.nix`). Read this for the reasoning, not the dep list.

Research for [palimpsest #84](https://github.com/inkpot-monkey/palimpsest/issues/84)
(wayfinder map [#61](https://github.com/inkpot-monkey/palimpsest/issues/61)).
Grounds the decision in the **actual** dependency closure of the fork at
`~/code/supernote` (`fix/device-schedule-group-all` @ `566022c`), not a generic survey.

## Question

The fork is a Python (aiohttp/asyncio + SQLite) app, not in nixpkgs. The #66 spike
ran it via a throwaway `uv` venv with `LD_LIBRARY_PATH` hacks for the numpy/Pillow
manylinux wheels. Decide the production packaging approach — nominally **uv2nix vs
poetry2nix vs an FHS/nix-ld env** — surveyed against this app's real dep set,
aarch64 (rk1b) buildability, and the maintenance cost of tracking the fork.

## Headline

**Package it with plain nixpkgs `buildPythonApplication` on `python313`, plus a
~15-line overlay for the two deps missing from nixpkgs.** None of the three
options the ticket named is warranted. The premise behind them — "this app has
awkward wheels that need a wheel-oriented tool or an impure escape hatch" —
does not survive contact with the dependency list.

## Why the wheel problem evaporates

The spike's pain (`LD_LIBRARY_PATH=<cc.cc.lib>:<zlib>`, uv's managed CPython that
NixOS can't exec) was entirely a consequence of installing **PyPI manylinux
wheels** onto NixOS. nixpkgs already carries native, patched builds of every
compiled dependency, so that class of problem simply doesn't exist when you build
against `python313Packages`.

The fork declares **7 core + 14 server + 3 client** dependencies; the full
transitive closure in `uv.lock` is **71 packages**. Availability in nixpkgs
(`python313Packages`, checked live):

| Dep (fork) | In nixpkgs? | Notes |
|---|---|---|
| numpy, Pillow, reportlab | ✅ native | the *only* compiled deps; the spike's whole problem |
| colour, pypng, svgwrite, potracer\* | ✅ / ⚠️ | `potracer` **missing** — pure-Python (`py2.py3-none-any`), dep = numpy |
| aiohttp, aiosqlite, aiofiles, aiohttp-remotes | ✅ | |
| SQLAlchemy[asyncio], alembic | ✅ | |
| mashumaro, pyyaml, PyJWT, requests, tqdm | ✅ | |
| starlette, prometheus-client, aiohttp-asgi\* | ✅ / ⚠️ | `aiohttp-asgi` **missing** — pure-Python (`py3-none-any`), dep = aiohttp |
| google-genai, mcp | ✅ | present but **unused in v1** — see wrinkle 1 |

**Result: 69 of 71 packages are already in nixpkgs.** The two gaps —
`potracer 0.0.4` and `aiohttp-asgi 0.6.1` — are both pure-Python universal
wheels whose only dependencies (numpy, aiohttp) are themselves in nixpkgs. Each
is a trivial `buildPythonPackage` (fetch sdist, `pyproject = true`, one
`propagatedBuildInput`). No C toolchain, no autoPatchelf, no impurity.

## aarch64 (rk1b) is a binary-substitute win, not a build

rk1b is aarch64 and A76-bound; a local numpy/Pillow compile there is expensive.
Checked against `cache.nixos.org` for `aarch64-linux`:

- `numpy`, `Pillow`, `reportlab` → **all CACHED**. rk1b pulls substitutes; it
  never compiles the heavy deps.

This is the decisive axis. The wheel-oriented tools invert it:

- **uv2nix / poetry2nix** build each dep from the *PyPI* wheel or sdist named in
  the lock file. On aarch64 that means either an aarch64 manylinux wheel
  (needs `autoPatchelfHook` + the exact `LD_LIBRARY_PATH` libraries the spike
  hand-fed, now productionised per-dep) or — when no aarch64 wheel exists — a
  **from-sdist numpy compile on rk1b**. Neither is cached by hydra.
- **nixpkgs-native** gets hydra's aarch64 binary cache for free.

## The three named options, and why each loses here

- **poetry2nix** — mature, but the fork ships `uv.lock` + a setuptools backend,
  not Poetry; adopting it means introducing and maintaining a `poetry.lock`.
  It also re-derives every dep from PyPI, forfeiting the aarch64 cache above, and
  adds a heavyweight input to the flake. No upside for a 2-package gap.
- **uv2nix** — matches the fork's toolchain (`uv.lock` exists) and is the
  strongest of the three, but it is comparatively young, pulls a large
  `pyproject-nix`/`uv2nix` machinery into the flake, and still builds from PyPI
  wheels → the aarch64 substitution loss + per-dep `autoPatchelf` fixups. Its one
  real advantage (auto-following the lock file) is small here because the fork's
  version constraints are all permissive lower-bounds (`>=`), so nixpkgs' newer
  pins satisfy them (e.g. fork wants `starlette>=0.35.0`, nixpkgs has `1.1.0`;
  `aiohttp>=3.13.2` vs `3.14.1`; `SQLAlchemy>=2.0.0` vs `2.0.51`).
- **FHS / nix-ld env** — productionises the spike's hack rather than fixing it:
  a `buildFHSEnv` (or `nix-ld` + venv) running `pip install` at build/first-run.
  Impure, defeats reproducibility, still fetches wheels, and gives the weakest
  aarch64 story. Only justified when a dep is genuinely unpackageable; nothing
  here is.

## Recommendation for the spec

Package as a nixpkgs Python application. Concretely, the build phase (out of
scope for this map, sketched only to make the approach unambiguous):

```nix
# overlay: the two pure-Python deps missing from nixpkgs
potracer = python3Packages.buildPythonPackage rec {
  pname = "potracer"; version = "0.0.4"; pyproject = true;
  src = fetchPypi { inherit pname version; hash = "..."; };
  build-system = [ python3Packages.setuptools ];
  propagatedBuildInputs = [ python3Packages.numpy ];
};
aiohttp-asgi = python3Packages.buildPythonPackage rec {
  pname = "aiohttp-asgi"; version = "0.6.1"; pyproject = true;
  src = fetchPypi { pname = "aiohttp_asgi"; inherit version; hash = "..."; };
  build-system = [ python3Packages.setuptools ];
  propagatedBuildInputs = [ python3Packages.aiohttp ];
};

# the fork itself, from the flake input tracking the branch (#85)
supernote = python3Packages.buildPythonApplication {
  pname = "supernote"; version = "0.16.0"; pyproject = true;
  src = supernoteFork;                       # flake input, branch-tracked
  build-system = [ python3Packages.setuptools ];
  dependencies = with python3Packages; [
    colour numpy pillow potracer pypng reportlab svgwrite       # core
    aiohttp mashumaro pyyaml pyjwt sqlalchemy alembic aiosqlite  # server
    aiofiles aiohttp-remotes starlette prometheus-client
    aiohttp-asgi google-genai mcp
    requests tqdm                                                # client
  ];
};
```

Both the server (`supernote-server serve` — the Private Cloud Sync endpoint the
Nomad talks to) and the reconcilers' client path (`supernote.client`) come from
the single `supernote[all]` package, so one derivation covers both #68 and #83.

## Wrinkles the spec must call out

1. **`google-genai` + `mcp` ride in the `server` extra but are v1-unused.** The
   map rules the fork's LLM/semantic features out of v1, yet both are hard deps of
   `supernote[server]`, so they land in the runtime closure regardless. Both are in
   nixpkgs and pure-Python-ish, so the cheap call is **accept them in the closure**
   (a handful of extra store paths) rather than patching `pyproject.toml` to split
   them out — patching would create a fork-of-the-fork delta to maintain across
   every rebase. Recommend: accept; note it so the closure size isn't a surprise.
1. **Pin `python313`, not `python314`.** `requires-python = ">=3.13"`; the
   `.python-version 3.14` / `python:3.14-slim` Dockerfile are dev-env artifacts.
   The #66 spike ran green on nixpkgs **python313**, whose package set is complete
   and cached (including aarch64). `python314Packages` coverage/caching is not
   guaranteed today — only revisit if a future fork bump *requires* 3.14.
1. **Dep-list drift is the one manual maintenance cost.** Consuming the fork as a
   branch-tracked flake input (#85) means `nix flake update supernote` can pull a
   commit that adds/removes a dependency. The hand-written `dependencies` list
   won't auto-follow — but a missing dep fails the build loudly (`ModuleNotFound`
   at import / `pythonImportsCheck`), so drift is caught at rebuild, not in
   production. A new dep *outside* nixpkgs adds one more `buildPythonPackage` stub
   (the two above are the current precedent). This is strictly cheaper than the
   per-dep aarch64 wheel-fixups the wheel tools would need on every bump.
1. **Guard the `>=`-vs-nixpkgs gap with a build-time smoke test.** Because we
   follow nixpkgs' newer pins rather than `uv.lock`, a nixpkgs major bump
   (SQLAlchemy, starlette, aiohttp) could in principle break the fork. Mitigation
   is cheap: the fork is TDD'd (388 green); run `pythonImportsCheck` +
   the server's `--help`/startup in `installCheckPhase`, or a tiny VM check, so a
   bad bump fails the build. (Test *execution* is build-phase; the spec just
   mandates the check exists.)

## One-line answer for the map

Plain nixpkgs `buildPythonApplication` on **python313** + a ~15-line overlay for
`potracer` and `aiohttp-asgi` (the only 2 of 71 deps missing from nixpkgs).
Rejects uv2nix/poetry2nix/FHS: 69/71 deps are already packaged, the compiled
ones (numpy/Pillow/reportlab) are aarch64-**cached** for rk1b, and the fork's
`>=` constraints are satisfied by nixpkgs' pins — so the wheel/`LD_LIBRARY_PATH`
problem the spike hit never arises. Cost: a hand-maintained dependency list
(drift caught loudly at rebuild) + accepting unused `google-genai`/`mcp` in the
closure.

## Implementation notes (built in #91)

The package landed as `pkgs/supernote/default.nix` (`pkgs.supernote`), consuming
the `supernote` flake input pinned in `flake.lock`. Three things the survey did
not predict, recorded so the next `nix flake update supernote` bump knows them:

1. **`aiohttp-asgi` builds with `poetry-core`, not setuptools.** Its `pyproject.toml`
   declares the `poetry.core.masonry.api` backend; a setuptools `build-system`
   fails with `BackendUnavailable`. `potracer` is setuptools as expected.
1. **nixpkgs' `aiohttp-remotes` 1.3.0 fails its *own* pytest against aiohttp 3.14**
   (a `BasicAuth` `DeprecationWarning` its strict `filterwarnings=error` promotes
   to a failure). The X-Forwarded code path the server uses is unaffected, so the
   package overrides it with `doCheck = false` rather than pinning an older aiohttp.
   Net: 4 tiny pure-Python derivations build from source on rk1b (`supernote`,
   `potracer`, `aiohttp-asgi`, `aiohttp-remotes`); numpy/Pillow/reportlab still
   substitute — confirmed via an `aarch64-linux` dry-run.
1. **Import names:** `potracer` imports as `potrace`; `aiohttp-asgi` as `aiohttp_asgi`.

The build-time guard is `pythonImportsCheck = [ supernote, supernote.client, supernote.server ]` plus an `installCheckPhase` running `supernote --help` and
`supernote-server serve --help` (imports the whole server stack).

**Reconcile:** the abandoned `supernote reconcile` fork subcommand (was #89) is
*not* part of this package. The round-trip reconciler is built on the fork's
existing client surface — the `supernote cloud` CLI and the `supernote.client`
async API — both shipped by this one `supernote[all]` derivation.
