# Stump 0.1.6 — a TEMPORARY in-repo override that runs ahead of nixpkgs.
#
# REMOVAL CONDITION: delete this directory and the `stump = ...` line in
# pkgs/default.nix as soon as the nixpkgs PIN ships stump >= 0.1.6. Check after
# any `nix flake update nixpkgs` with
#   nix eval .#inputs.nixpkgs.legacyPackages.x86_64-linux.stump.version
# (upstream's file to watch is pkgs/by-name/st/stump/package.nix). Nothing else
# has to change on the way out: `pkgs.stump` comes from the
# `additions` overlay (modules/shared/overlays), so this attribute shadows
# nixpkgs' own — deleting these two things IS the whole revert, and every
# consumer keeps saying `pkgs.stump`.
#
# Why carry it: upstream released 0.1.6 on 2026-08-02 and nixpkgs — master
# included — is still on 0.1.5. 0.1.6 fixes KOReader progress fetching, which is
# precisely the integration the Supernote document-library round-trip depends on
# (ADR-0031, palimpsest#87/#111). Standing the catalog up at 0.1.6 also means it
# is created fresh and never runs the 0.1.5 reading-session migration, which
# upstream shipped with an explicit data-loss warning.
#
# Shape: nixpkgs' own pkgs/by-name/st/stump/package.nix, copied at 0.1.5 and
# changed in five places (a copy rather than an `overrideAttrs`: buildRustPackage
# reads `cargoHash` from its *original* argument set, so an overlay bump has to
# reach past it and rebuild `cargoDeps` by hand, and the web frontend is a nested
# derivation carrying a second vendor hash — the indirection costs more than it
# saves for something meant to be deleted). The five deltas:
#   1. version + all three hashes bumped to 0.1.6 (Cargo.lock and yarn.lock both
#      moved between the releases, so the Rust and web vendor hashes both change).
#   2. `doCheck = false`, and gtk3/webkitgtk_4_1 dropped with it — those are only
#      needed to compile the Tauri desktop app that upstream's whole-workspace
#      `cargo test` drags in. rk1b is aarch64 and builds this from source.
#   3. aarch64-linux added to meta.platforms; nixpkgs only ever claimed x86_64,
#      but rk1b (the deployment target) is aarch64.
#   4. an installCheck asserting the server binary starts and reports 0.1.6 (see
#      the note on it below).
#   5. passthru dropped: `nixosTests.stump` would exercise nixpkgs' unoverlaid
#      0.1.5, and `nix-update-script` is wrong for a deliberately pinned override.
{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchYarnDeps,
  yarnConfigHook,
  rustPlatform,
  nodejs,
  pdfium-binaries,
  openssl,
  dbus,
  glib,
  pkg-config,
  makeWrapper,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "stump";
  version = "0.1.6";

  src = fetchFromGitHub {
    owner = "stumpapp";
    repo = "stump";
    tag = "v${finalAttrs.version}";
    hash = "sha256-y870qA9r9uhFJthKiz0uIu6xFMtZ0L5xBj4iRr20/QI=";
  };

  # The React SPA the server hands out from STUMP_CLIENT_DIR, built offline from
  # the same source tree's yarn v1 lockfile.
  frontend = stdenv.mkDerivation (_: {
    pname = "stump-frontend";
    inherit (finalAttrs) src version;

    yarnOfflineCache = fetchYarnDeps {
      yarnLock = finalAttrs.src + "/yarn.lock";
      hash = "sha256-j+S3FkiWZRZyX3CfwEDbspjG+oltECgIFOZZuN7FKRY=";
    };

    nativeBuildInputs = [
      yarnConfigHook
      nodejs
    ];

    buildPhase = ''
      runHook preBuild

      pushd apps/web
      node ./node_modules/.bin/vite build
      popd

      runHook postBuild
    '';

    installPhase = ''
      mv ./apps/web/dist $out
    '';
  });

  __structuredAttrs = true;

  cargoHash = "sha256-2WI/sjRM9GESBc3APrTwQ2F28CPkZCUfzEE+EMMWHKA=";

  cargoBuildFlags = [
    "--package"
    "stump_server"
    "--bin"
    "stump_server"
  ];

  # The server stamps its build with the git rev; a fetchFromGitHub tree has no
  # .git, so hand it the tag.
  env.GIT_REV = "v${finalAttrs.version}";

  nativeBuildInputs = [
    pkg-config
    makeWrapper
  ];

  buildInputs = [
    openssl
    dbus
    glib
  ];

  # Upstream's `cargo test` runs over the entire workspace — including the Tauri
  # desktop app, which this package does not build and which drags in gtk3 and
  # webkitgtk. The installCheck below is the build-phase guard instead, the same
  # bargain pkgs/supernote strikes.
  doCheck = false;

  postInstall = ''
    wrapProgram $out/bin/stump_server \
      --set-default STUMP_CONFIG_DIR /var/lib/stump/config \
      --set-default STUMP_CLIENT_DIR ${finalAttrs.frontend} \
      --set-default STUMP_PORT 10001 \
      --set-default STUMP_PROFILE release \
      --set-default PDFIUM_PATH ${pdfium-binaries}/lib/libpdfium.so \
      --set-default API_VERSION v1
  '';

  # The reason this override is safe to carry: the server binary has to actually
  # start and report the version we claim, or the build fails. `stump_server`
  # bootstraps its config directory *before* clap parses argv, so point that at a
  # scratch dir — the wrapper's default /var/lib/stump/config is not writable in
  # the sandbox. Verified to discriminate: run against nixpkgs' 0.1.5 this same
  # script fails with `stump_server --version: stump 0.1.5`.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    export STUMP_CONFIG_DIR="$(mktemp -d)"
    reported="$($out/bin/stump_server --version)"
    echo "stump_server --version: $reported"
    case "$reported" in
      *${finalAttrs.version}*) ;;
      *)
        echo "expected stump_server to report ${finalAttrs.version}, got: $reported" >&2
        exit 1
        ;;
    esac

    # The SPA the wrapper points STUMP_CLIENT_DIR at has to exist, or the server
    # comes up serving a blank page.
    test -s ${finalAttrs.frontend}/index.html

    runHook postInstallCheck
  '';

  meta = {
    homepage = "https://stumpapp.dev/";
    description = "A free and open source comics, manga and digital book server with OPDS support";
    changelog = "https://github.com/stumpapp/stump/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    maintainers = [ ];
    # nixpkgs claims x86_64-linux only; rk1b, the deployment target, is aarch64.
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "stump_server";
  };
})
