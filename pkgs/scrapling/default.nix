# Scrapling — a scraping framework that returns parsed, adaptive selectors and can fetch
# through a stealth browser. Packaged for the agent host: hermes reaches it as both a
# library (`import scrapling`) and two console scripts (`scrapling`, `scrapling-mcp`),
# via the `python3.withPackages` in modules/nixos/profiles/hermes.nix.
#
# NOT IN NIXPKGS (checked at the current pin: no `python3Packages.scrapling`), and its
# one missing dependency is patchright, which nixpkgs ships `broken = true` for reasons
# that are not going to change — see pkgs/patchright for that whole story.
#
# EVERY OTHER DEPENDENCY, INCLUDING ALL FOUR EXTRAS, IS ALREADY IN THE PIN. That is why
# this is a plain `buildPythonPackage` and not a vendored dependency tree: lxml,
# curl-cffi, playwright, browserforge, apify-fingerprint-datapoints, msgspec, protego,
# markdownify, mcp and ipython all exist at or above the versions upstream asks for, and
# the aarch64 ones substitute rather than compile.
#
# The full `all` extra is taken rather than the bare core, deliberately: the extras are
# what make it worth having here. `fetchers` is the browser half, `ai` is the MCP server
# (`scrapling-mcp`, which is how an agent would use this over a tool call rather than a
# shell pipe), `rag` is the markdown conversion a model actually wants to read, and
# `shell` is the interactive REPL. Omitting any of them would not shrink the closure
# much — they share the same heavy roots — and would turn a working subcommand into an
# ImportError at first use.
{
  lib,
  python3,
  fetchFromGitHub,
  patchright,
  playwright-driver,
}:

python3.pkgs.buildPythonPackage {
  pname = "scrapling";
  version = "0.5.1";

  pyproject = true;

  src = fetchFromGitHub {
    owner = "D4Vinci";
    repo = "Scrapling";
    tag = "v0.5.1";
    hash = "sha256-qFnZ5BlGDH9+dTrcc2aedQfmRUFA0JcHcTRXOU84v94=";
  };

  build-system = [ python3.pkgs.setuptools ];

  # ⚠ THE PIN HAS protego 0.6.2 AND UPSTREAM ASKS FOR >= 0.7.0. Relaxed rather than
  # overridden because the two call sites (`spiders/robotstxt.py`,
  # `spiders/templates/sitemap.py`) use only `Protego.parse`, `can_fetch` and `sitemaps`,
  # all of which 0.6.2 has — and 0.7.0 is a maintenance release, not an API break.
  # Packaging a second protego to satisfy a lower bound nothing exercises would cost a
  # fork of the dependency for no behaviour. Drop this the moment the pin moves past
  # 0.7.0: `nix eval .#nixosConfigurations.rk1b.pkgs.python3Packages.protego.version`.
  pythonRelaxDeps = [ "protego" ];

  dependencies =
    (with python3.pkgs; [
      # core
      lxml
      cssselect
      orjson
      tld
      w3lib
      typing-extensions
      # [fetchers]
      click
      curl-cffi
      playwright
      browserforge
      apify-fingerprint-datapoints
      msgspec
      anyio
      protego
      # [rag] / [ai] / [shell]
      markdownify
      mcp
      ipython
    ])
    ++ [
      # [fetchers], but from this repo rather than the Python set — see pkgs/patchright.
      patchright
    ];

  # ── WHERE THE BROWSERS COME FROM ───────────────────────────────────────────────────
  # patchright's node driver finds its chromium through PLAYWRIGHT_BROWSERS_PATH, and
  # otherwise wants to DOWNLOAD one into ~/.cache at first use — which on a NixOS agent
  # host means a prebuilt binary that will not run and a cache directory that does not
  # survive impermanence. nixpkgs' playwright-driver is on 1.64.1 and patchright 1.64.4
  # vendors patchright-core 1.64.3, i.e. the same chromium revision (1248), so the stock
  # bundle is the right one; patchright's stealth work is in the driver JS, not in a
  # patched browser.
  #
  # ⚠ THIS COVERS THE CONSOLE SCRIPTS ONLY. A wrapper's environment reaches what it
  # launches, so `import scrapling` from a bare `python3` does not get it — the hermes
  # profile sets the same variable on the unit for that reason, and the two are expected
  # to agree. (Contrast the node path, which pkgs/patchright substitutes into the library
  # itself precisely so it needs no wrapper.)
  #
  # MEASURED ON rk1b at the commit that added this, both ways round against a local
  # server: `scrapling extract fetch` (the wrapped script) and `StealthyFetcher.fetch`
  # under a bare interpreter with only PLAYWRIGHT_BROWSERS_PATH exported, the shape the
  # unit produces. Both returned 200 through a real chromium, so the bundle and the
  # substituted node path are both right. The skip flag below is the wrapper's alone and
  # the library path does not need it — playwright's host-requirements check passes here.
  makeWrapperArgs = [
    "--set-default"
    "PLAYWRIGHT_BROWSERS_PATH"
    "${playwright-driver.browsers}"
    "--set-default"
    "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS"
    "1"
  ];

  # Upstream's test suite scrapes live websites; there is nothing it could do in the
  # sandbox but fail.
  doCheck = false;

  pythonImportsCheck = [
    "scrapling"
    "scrapling.cli"
    # The two surfaces that pull the extras in. Worth naming explicitly: the first build
    # of this package imported `scrapling` fine and only broke on the fetchers, because
    # the top-level package is lazy about its heavy imports.
    "scrapling.fetchers"
    "scrapling.integrations"
  ];

  meta = {
    description = "Undetectable, powerful, flexible, high-performance Python web scraping framework";
    homepage = "https://github.com/D4Vinci/Scrapling";
    changelog = "https://github.com/D4Vinci/Scrapling/releases/tag/v0.5.1";
    license = lib.licenses.bsd3;
    mainProgram = "scrapling";
    platforms = patchright.meta.platforms;
  };
}
