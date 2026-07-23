# The Supernote toolkit fork (github:inkpot-monkey/supernote), packaged with
# nixpkgs `buildPythonApplication` on python313. Rationale and the
# survey-against-the-real-dep-set is in research/supernote-packaging-approach.md:
# 20 of 22 runtime deps are already in `python313Packages` (numpy/Pillow/reportlab
# are aarch64-cached, so rk1b substitutes them rather than compiling); only
# `potracer` and `aiohttp-asgi` are missing, and both are pure-Python universal
# wheels stubbed below. The fork's version constraints are all `>=` lower bounds,
# satisfied by nixpkgs' newer pins.
#
# `src` is the `supernote` flake input (pinned in flake.lock, bumped via
# `nix flake update supernote`), threaded through pkgs/default.nix.
{
  lib,
  python313,
  fetchPypi,
  src,
}:
let
  python = python313;

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
  # Display label only; `src` (the branch-tracked flake input) is the real pin.
  # Bump to match the fork's pyproject on a `nix flake update supernote` that
  # crosses a version — a stale label is cosmetic, not a build error.
  version = "0.16.0";
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
      mcp
      starlette
    ])
    ++ [
      python.pkgs.google-genai
      python.pkgs.prometheus-client
      aiohttp-remotes
      potracer
      aiohttp-asgi
    ];

  # Build-time smoke: import the client + server trees (guards the permissive
  # `>=`-vs-nixpkgs-pins gap — a bad `nix flake update` that breaks an import
  # fails the build here rather than at runtime on rk1b).
  pythonImportsCheck = [
    "supernote"
    "supernote.client"
    "supernote.server"
  ];

  # The fork's own pytest suite needs a device/network and dev-only deps; the
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
    description = "Supernote toolkit fork: parse notebooks, self-host Private Cloud Sync, access services";
    homepage = "https://github.com/inkpot-monkey/supernote";
    license = lib.licenses.asl20;
    maintainers = [ ];
    mainProgram = "supernote";
    platforms = lib.platforms.linux;
  };
}
