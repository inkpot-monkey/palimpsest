# The UPSTREAM Supernote toolkit (github:allenporter/supernote), packaged with nixpkgs
# `buildPythonApplication` on python313. Rationale and the survey-against-the-real-dep-set
# is in research/supernote-packaging-approach.md: nearly every runtime dep is already in
# `python313Packages` (numpy/Pillow/reportlab are aarch64-cached, so rk1b substitutes them
# rather than compiling); only `potracer` and `aiohttp-asgi` are missing, and both are
# pure-Python universal wheels stubbed below. Upstream's version constraints are all `>=`
# lower bounds, satisfied by nixpkgs' newer pins.
#
# palimpsest#112 retired the vendored `inkpot-monkey/supernote` fork this used to track.
# Relative to that fork's `[all]` set, upstream changed the dependency set in three ways:
#   • + python-socketio (in nixpkgs) — the device realtime channel. Upstream serves socket.io
#     with the real library (`allow_eio3=True`, supernote/server/socket.py), replacing the
#     fork's hand-rolled EIO3 `supernote/server/realtime.py`. The SERVER imports it
#     unconditionally; only the client tree guards it (`supernote/client/__init__.py`
#     try/except ImportError), so it must be present or the server fails at IMPORT, not at
#     first connect.
#   • + ical (in nixpkgs) — the `GET /api/schedule/feed.ics` VTODO export
#     (services/ical_export.py).
#   • `mcp>=1.25.0` → `>=2.0.0` — NOT in nixpkgs. The fleet pin ships 1.26.0, whose layout has
#     no `mcp.server.mcpserver`, which `server/app.py` imports at module scope. Hence the local
#     `mcp2` chain below (./mcp2.nix). This is the one genuinely awkward part of the cutover;
#     that file documents why rolling the rev back instead does not work.
#
# `src` is the `supernote` flake input — pinned to an explicit REV in flake.nix (not a branch),
# so it never moves under an unattended `nix flake update`; threaded through pkgs/default.nix.
{
  lib,
  python313,
  fetchPypi,
  src,
}:
let
  python = python313;

  # MCP SDK 2.x. Upstream needs `mcp>=2.0.0` and imports `mcp.server.mcpserver` at module
  # scope; the fleet nixpkgs pin still ships 1.26.0, whose layout lacks it. Built locally
  # (with its httpx2/httpcore2/mcp-types chain) until nixpkgs catches up — see ./mcp2.nix,
  # which is written to be deleted wholesale.
  mcp2 = import ./mcp2.nix { inherit python; };

  # potracer 0.0.4 — pure-Python Potrace port (imports as `potrace`). Missing
  # from nixpkgs; only dep is numpy.
  potracer = python.pkgs.buildPythonPackage rec {
    pname = "potracer";
    version = "0.0.4";
    pyproject = true;
    src = fetchPypi {
      inherit pname version;
      hash = "sha256-MsvbmERGBmvPvotgAUKlS5D6baJ0tpIZRzIF1uTAlxM=";
    };
    build-system = [ python.pkgs.setuptools ];
    dependencies = [ python.pkgs.numpy ];
    pythonImportsCheck = [ "potrace" ];
    doCheck = false;
  };

  # aiohttp-asgi 0.6.1 — mounts an ASGI app inside aiohttp (the server's MCP/auth
  # catch-all). Missing from nixpkgs; only dep is aiohttp.
  aiohttp-asgi = python.pkgs.buildPythonPackage rec {
    pname = "aiohttp-asgi";
    version = "0.6.1";
    pyproject = true;
    src = fetchPypi {
      pname = "aiohttp_asgi";
      inherit version;
      hash = "sha256-vIbeycDkqsddgpl+qCAcfqdEOEHxaPmX2ncW0NTe+dU=";
    };
    build-system = [ python.pkgs.poetry-core ];
    dependencies = [ python.pkgs.aiohttp ];
    pythonImportsCheck = [ "aiohttp_asgi" ];
    doCheck = false;
  };

  # nixpkgs' aiohttp-remotes 1.3.0 fails its *own* pytest suite against aiohttp
  # 3.14 (a BasicAuth DeprecationWarning its strict `filterwarnings=error` config
  # promotes to a failure). The X-Forwarded setup the server uses is unaffected,
  # so skip that flaky upstream check rather than pinning an older aiohttp.
  aiohttp-remotes = python.pkgs.aiohttp-remotes.overridePythonAttrs (_: {
    doCheck = false;
  });
in
python.pkgs.buildPythonApplication {
  pname = "supernote";
  # Display label only; `src` (the rev-pinned flake input) is the real pin. Bump to match
  # upstream's pyproject when the rev in flake.nix crosses a version — a stale label is
  # cosmetic, not a build error.
  version = "0.17.0";
  pyproject = true;
  inherit src;

  build-system = [ python.pkgs.setuptools ];

  # supernote[all] = core + client + server. Hyphenated attrs are referenced
  # explicitly because they are not valid identifiers inside `with`.
  dependencies =
    (with python.pkgs; [
      # core (potracer is the local stub, added below)
      colour
      numpy
      pillow
      pypng
      reportlab
      svgwrite
      # client
      aiohttp
      requests
      tqdm
      # server
      mashumaro
      pyyaml
      pyjwt
      sqlalchemy
      alembic
      aiosqlite
      aiofiles
      starlette
      # client + server: the device realtime socket.io channel (see the header).
      python-socketio
      # server: the schedule feed.ics VTODO export.
      ical
    ])
    ++ [
      python.pkgs.google-genai
      python.pkgs.prometheus-client
      aiohttp-remotes
      potracer
      aiohttp-asgi
      mcp2
    ];

  # Build-time smoke: import the client + server trees (guards the permissive
  # `>=`-vs-nixpkgs-pins gap — a bad rev bump that breaks an import fails the build
  # here rather than at runtime on rk1b). The last two are named explicitly because
  # they are the palimpsest#112 additions: `server.socket` is the device realtime
  # channel (needs python-socketio) and `services.ical_export` the feed.ics export
  # (needs ical) — so a missing new dep fails HERE, by name, not as an opaque
  # `serve --help` traceback.
  pythonImportsCheck = [
    "supernote"
    "supernote.client"
    "supernote.server"
    "supernote.server.socket"
    "supernote.server.services.ical_export"
  ];

  # Upstream's own pytest suite needs a device/network and dev-only deps; the
  # import check + server-startup check below are the build-phase guard instead.
  doCheck = false;

  # Server-startup check: `supernote-server serve --help` constructs the arg
  # parser and imports `supernote.server.app` (starlette/sqlalchemy/aiohttp/
  # prometheus/aiohttp-asgi), so an unsatisfiable server dep surfaces at build.
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/supernote --help > /dev/null
    $out/bin/supernote-server serve --help > /dev/null
    runHook postInstallCheck
  '';
  doInstallCheck = true;

  meta = {
    description = "Supernote toolkit: parse notebooks, self-host Private Cloud Sync, access services";
    homepage = "https://github.com/allenporter/supernote";
    license = lib.licenses.asl20;
    maintainers = [ ];
    mainProgram = "supernote";
    platforms = lib.platforms.linux;
  };
}
