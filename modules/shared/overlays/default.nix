{ inputs, ... }:
let
  # 1. Additions: Your custom packages
  additions =
    final: _prev:
    import (inputs.self + /pkgs/default.nix) {
      pkgs = final;
      inherit inputs;
    };

  # 2. Modifications: Your overrides
  modifications = {
    # Pin snapcast to 0.34.0 fleet-wide (only porcupineFish actually pulls it into a
    # closure). Music Assistant 2.9.x drives an *external* snapserver and is developed +
    # tested against snapserver 0.34.0 (its Dockerfile.base sets SNAPCAST_VERSION=0.34.0);
    # nixpkgs' 0.35.0 is one minor ahead of that, unverified, and changes the dynamic
    # Stream.RemoveStream teardown path MA relies on (0.30 was broken, 0.32 broke MA per
    # snapcast#1410). Hold the tested pairing until a bump is verified on the box.
    # See docs/adr/0031-porcupinefish-sound-server-audio.md.
    # HOLD: docs/holds.md#snapcast
    snapcast = final: prev: {
      snapcast = prev.snapcast.overrideAttrs (_old: {
        version = "0.34.0";
        src = final.fetchFromGitHub {
          owner = "badaix";
          repo = "snapcast";
          rev = "v0.34.0";
          hash = "sha256-BPsAGFLWUfONuyQ1pzsJzGV/Jlxv+4TkVT1KG7j8H0s=";
        };
      });
    };

    tree-sitter = final: prev: {
      tree-sitter-grammars = prev.tree-sitter-grammars // {
        tree-sitter-quint = final.tree-sitter.buildGrammar {
          language = "quint";
          version = "release";
          src = final.fetchFromGitHub {
            owner = "gruhn";
            repo = "tree-sitter-quint";
            rev = "release";
            hash = "sha256-WVSRFaj+X/S4DgyA6nWmRO+99iWG9Tr5hVrj53VB8E4=";
          };
        };
        tree-sitter-svelte = final.tree-sitter.buildGrammar {
          language = "svelte";
          version = "latest";
          src = final.fetchFromGitHub {
            owner = "tree-sitter-grammars";
            repo = "tree-sitter-svelte";
            rev = "ae5199db47757f785e43a14b332118a5474de1a2";
            hash = "sha256-cH9h7i6MImw7KlcuVQ6XVKNjd9dFjo93J1JdTWmEpV4=";
          };
        };
        tree-sitter-astro = final.tree-sitter.buildGrammar {
          language = "astro";
          version = "master";
          src = final.fetchFromGitHub {
            owner = "virchau13";
            repo = "tree-sitter-astro";
            rev = "master";
            hash = "sha256-TpXs3jbYn39EHxTdtSfR7wLA1L8v9uyK/ATPp5v4WqE=";
          };
        };
      };
    };

    # ── PACKAGES TAKEN FROM THE STABLE RELEASE, BECAUSE THEY CANNOT BUILD ON UNSTABLE ──
    # Taken from `nixpkgs-stable` (the current NixOS release branch — see flake.nix). Each
    # entry is a package that FAILS TO BUILD on unstable, not one we merely prefer older.
    #
    # ⚠ AND THESE ARE NOT DOWNGRADES. Measured 2026-11-10, stable carries the SAME VERSIONS
    # unstable is trying and failing to build — matrix-tuwunel 1.9.4, stalwart 0.15.5,
    # matrix-hookshot 7.6.0 — and all three are substitutable there (narinfo 200) where the
    # unstable paths are 404. So this costs no version and no build: it is the identical
    # software, from the branch where it was actually compiled.
    #
    # THE SHARED CAUSE. nixpkgs is midway through moving Rust `*-sys` crates onto system
    # libraries via `default-crate-overrides` — zstd-sys (2026-06-16), libsqlite3-sys
    # (2026-10-20), aws-lc-sys (2026-10-23 and 10-30). Each flip requires every dependent
    # package to gain that library in `buildInputs`, and upstream adds those one package at a
    # time (cargo-nextest, vrc-get, topgrade and mqttui all carry "add aws-lc" commits). The
    # 2026-11-07 channel rev sits in the middle of that fallout, so these die in a build
    # script or at link time:
    #
    #   matrix-tuwunel   aws-lc-sys       "AWS_LC_SYS_USE_SYSTEM=1 requires a system-installed
    #                                      AWS-LC, but none was found"
    #   stalwart         zstd-sys         "The system library `libzstd` required by crate
    #                    (via trunk → webadmin)   `zstd-sys` was not found"
    #   matrix-hookshot  libsqlite3-sys   ld: cannot find -lsqlite3, linking
    #                    (via matrix-sdk-crypto-nodejs)  matrix-sdk-crypto-nodejs
    #
    # There is no newer unstable to escape to: f4a03c00 IS nixos-unstable's head (2026-11-10).
    #
    # WHY STABLE AND NOT A PINNED REV OR A PATCH.
    #   * A frozen rev (the pre-bump unstable) was written first and rejected: it stops
    #     receiving security fixes, and these three are a federated homeserver, a mail server
    #     and a bridge — the worst possible set to abandon. It was also strictly worse on
    #     version, pinning tuwunel back to 1.9.3. A RELEASE BRANCH keeps getting backports.
    #   * An overlay adding the missing `buildInputs` is what upstream is doing and does work,
    #     but the result is in no cache, so every deploy would compile three large Rust trees
    #     from source.
    #
    # ⚠ REMOVE ENTRIES AS UPSTREAM FIXES THEM — this is a waiting room, not an architecture.
    # Check with:
    #   gh search commits --repo NixOS/nixpkgs matrix-tuwunel
    #   gh search commits --repo NixOS/nixpkgs "trunk zstd"
    # To re-test one, drop it here and build the host; a 404 narinfo on the unstable path means
    # it is still broken.
    #
    # ⚠ AND WATCH FOR MODULE/PACKAGE SKEW, which this repo has already been bitten by: the
    # paperless note in profiles/paperless.nix records a stable PACKAGE under an unstable
    # MODULE failing at eval, because the module read a passthru only the newer package had.
    # Module and package come from one pin by default for a reason; every entry here breaks
    # that deliberately, so each one needs the host to actually BUILD, not just evaluate.
    stable-until-fixed =
      _final: prev:
      let
        stable = inputs.nixpkgs-stable.legacyPackages.${prev.stdenv.hostPlatform.system};
      in
      {
        # HOLD: docs/holds.md#matrix-tuwunel
        # HOLD: docs/holds.md#stalwart
        # HOLD: docs/holds.md#matrix-hookshot
        inherit (stable) matrix-tuwunel stalwart matrix-hookshot;
      };

    # stump, built against the FROZEN nixpkgs rather than the fleet one.
    #
    # Same cause as the three above (nixpkgs moving `*-sys` crates onto system libraries)
    # but it cannot be solved the same way: stump is not in the stable branch, and this is
    # OUR derivation — so there is no upstream binary to borrow. The frozen rev is the one
    # thing that reproduces the store path rk1b is ALREADY RUNNING
    # (dgfx0q5dmk5gvhnvfx6szqw1s6vjgp0v-stump-0.1.6), making this pin free: no Rust rebuild
    # on the fleet's one aarch64 builder.
    #
    # ⚠ `callPackage` from the frozen set, NOT an override of the package produced by the
    # `additions` overlay — the point is to evaluate the file against the frozen stdenv and
    # rustPlatform, and overriding an already-built-against-unstable derivation would not.
    # pkgs/stump must therefore stay free of `zstd`/`sqlite` in `buildInputs` while this
    # pin stands: adding them changes the derivation hash and the free rebuild stops being
    # free. The full reasoning and the exit condition are in the registry entry:
    # HOLD: docs/holds.md#stump
    stump-pin = _final: _prev: {
      stump = inputs.nixpkgs-frozen.legacyPackages.${_prev.stdenv.hostPlatform.system}.callPackage (
        inputs.self + /pkgs/stump
      ) { };
    };

    # grafana, taken from the stable release because unstable's build LOST the Prometheus
    # datasource plugin — every metric panel on every dashboard renders "No data".
    #
    # ⚠ UNLIKE `stable-until-fixed` ABOVE, this one IS a downgrade and the unstable package
    # DOES build. It is a separate overlay for exactly that reason: the invariant documented
    # on that overlay ("fails to build", "not a downgrade") stays true.
    #
    # WHAT BROKE. Grafana 13.2 externalised its core datasource plugins, and nixpkgs' 13.3.0
    # update dropped `yarn run plugins:build-bundled` from `postBuild` while `postInstall`
    # still copies only `public conf`. So nothing builds or installs them. Measured on the
    # two store paths:
    #
    #   grafana-13.1.6  public/app/plugins/datasource/  20 entries, prometheus among them
    #   grafana-13.3.0  public/app/plugins/datasource/   7 entries, no prometheus
    #
    # The server says so itself — `plugin prometheus not found`, `Core plugin expected to be
    # loaded as external, but it is missing pluginID=canvas`, and, per query, `Could not find
    # plugin definition for data source datasource_type=prometheus`. The datasource health
    # endpoint returns `plugin.notRegistered`. VictoriaMetrics is untouched by this: the same
    # query answered straight off :8428 returns data, so only the Grafana leg is dark. The
    # VictoriaLogs datasource keeps working, which is why the log panels alone kept rendering.
    #
    # Landed on rk1b at generation 141, 2026-11-10, with the 13.1.6 -> 13.3.0 bump.
    #
    # WHY STABLE AND NOT THE FROZEN REV. Same reasoning as `stable-until-fixed`: a release
    # branch keeps getting backports and Grafana is a long-lived web service with its own
    # auth, so abandoning its security updates to hold a frozen rev is the worse trade. Costs
    # one minor (13.3.0 -> 13.0.12) and nothing in build time — the stable aarch64 path is
    # substitutable (narinfo 200).
    #
    # ⚠ MODULE/PACKAGE SKEW. The grafana MODULE still comes from unstable while the package
    # comes from stable, which is the skew `docs/holds.md` warns about. This pin must
    # therefore be validated by BUILDING rk1b, not by evaluating it.
    # HOLD: docs/holds.md#grafana
    grafana-pin =
      _final: prev:
      let
        stable = inputs.nixpkgs-stable.legacyPackages.${prev.stdenv.hostPlatform.system};
      in
      {
        inherit (stable) grafana;
      };

    # antigravity = final: prev: {
    #   antigravity = prev.antigravity.overrideAttrs (_: {
    #     version = "1.19.5";
    #     src = final.fetchurl {
    #       url = "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/1.19.5-5117559161880576/linux-x64/Antigravity.tar.gz";
    #       hash = "sha256-xGeNs24UwQCKGp4d3tj7jYdurqSXkmjYQF6f2Vwckm4=";
    #     };
    #   });
    # };
  };

  # 4. Flexget: Fix missing WebUI assets
  flexget = import ./flexget.nix { inherit inputs; };

in
{
  inherit additions modifications;

  # The "Single Overlay" that combines everything
  # Using composeManyExtensions is more robust than manual attribute merging
  default = inputs.nixpkgs.lib.composeManyExtensions [
    additions
    modifications.tree-sitter
    modifications.snapcast
    modifications.stable-until-fixed
    modifications.stump-pin
    modifications.grafana-pin
    # modifications.antigravity
    flexget
  ];
}
