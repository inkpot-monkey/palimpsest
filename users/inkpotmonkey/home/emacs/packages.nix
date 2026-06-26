{ pkgs, epkgs }:
# Custom Emacs packages not in MELPA/nixpkgs.
#
# Build choice — melpaBuild vs trivialBuild:
#   `melpaBuild` runs MELPA's package-build, which preserves upstream
#   `;;;###autoload` cookies into a generated `<pkg>-autoloads.el` and installs
#   under `share/emacs/site-lisp/elpa/`. The emacs wrapper loads those autoloads
#   at startup, so the package's commands are bound without the package being
#   required — exactly like a real MELPA package. `trivialBuild` only
#   byte-compiles top-level `.el` and emits NO autoloads, so deferred commands
#   stay void until something requires the package (this is what made
#   `(claude-code)` a void-function until a hand-added `:commands` patched it).
#
#   So melpaBuild is the default. Two packages stay on trivialBuild because their
#   structure is incompatible with package-build:
#     - consult-omni  ships a `sources/` subdir of backend files that must NOT be
#       byte-compiled (many soft-require absent network packages); trivialBuild
#       copies them verbatim, package-build would compile them and fail.
#     - ai-code-interface  has its main library in `ai-code.el`, not
#       `ai-code-interface.el`; package-build derives the main file from the
#       package name and would not find it.
{
  auth-source-sops = epkgs.melpaBuild {
    pname = "auth-source-sops";
    version = "0.1-unstable-2024-01-01";
    src = pkgs.fetchFromGitHub {
      owner = "inkpot-monkey";
      repo = "auth-source-sops";
      rev = "ca3a2d609e8a7bdb2d62c397e1e0cfbcfaa000cf";
      hash = "sha256-XPhiwX0GqneIS7bBxvSxW4LpP1/emYEPmcBG9mT6qUs=";
    };
    packageRequires = [ epkgs.yaml ];
  };

  # Upstream repo is `ai-code-interface.el`, but its main library is `ai-code.el`
  # and it `(provide 'ai-code)` — so the Emacs feature, the use-package name, and
  # this attr are all `ai-code`. (melpaBuild's package-build derives the main file
  # from pname and wouldn't find `ai-code.el`, so this stays on trivialBuild; see
  # the header note. trivialBuild emits no autoloads, so init.el's `:bind`
  # autoloads `ai-code-menu' from the `ai-code' feature directly.)
  ai-code = epkgs.trivialBuild {
    pname = "ai-code";
    version = "unstable-2026-06-19";
    src = pkgs.fetchFromGitHub {
      owner = "tninja";
      repo = "ai-code-interface.el";
      rev = "453281bd230d7004a517e3b288eff530c3b9d4de";
      hash = "sha256-7nx86SC/KFQ4v85YuwdCSyqnjXUkQp9/eiJnIn/QYGo=";
    };
    packageRequires = [ epkgs.magit ];
  };

  svelte-ts-mode = epkgs.melpaBuild {
    pname = "svelte-ts-mode";
    version = "0.1-unstable-2024-01-01";
    src = pkgs.fetchFromGitHub {
      owner = "leafOfTree";
      repo = "svelte-ts-mode";
      rev = "d079050fc1ba70f8fba9e596638daa2ca96e0fdd";
      hash = "sha256-uYHJP0PyGE27SsztrQCZyuIeHA9Y2x5cfD16BZihg5k=";
    };
  };

  # `sources/` backend files must ship uncompiled (they soft-require absent
  # network packages), so this stays on trivialBuild. See the header note.
  consult-omni = epkgs.trivialBuild {
    pname = "consult-omni";
    version = "unstable-202X";
    src = pkgs.fetchFromGitHub {
      owner = "armindarvish";
      repo = "consult-omni";
      rev = "bdcd5a065340dce9906ac5c5f359906d31877963";
      hash = "sha256-vmKKEmZpzHQ8RDbTuoTCWGRypLfMiHrEv9Zw0G6K1pg=";
    };
    packageRequires = [
      epkgs.consult
      epkgs.embark
      epkgs.embark-consult
      epkgs.transient
      epkgs.dash
      epkgs.f
    ];
    postInstall = ''
      cp -rv sources $out/share/emacs/site-lisp/
    '';
  };

  just-complete = epkgs.melpaBuild {
    pname = "just-complete";
    version = "1.2";
    src = ./just-complete;
  };

  claude-code = epkgs.melpaBuild {
    pname = "claude-code";
    version = "0.4.5";
    src = pkgs.fetchFromGitHub {
      owner = "stevemolitor";
      repo = "claude-code.el";
      rev = "03199df8b3a1e9cd4857f0851f7a912ba524aff3";
      hash = "sha256-5QJrWIu4EgnHcOqMwlrs2JBBx7aI9OaSJswesr6Apfk=";
    };
    packageRequires = [
      epkgs.transient
      epkgs.inheritenv
    ];
  };

  # ghostel pinned ahead of nixpkgs to 0.37.0. The nixos-unstable channel still
  # ships 0.34.0, which has a redraw-timer race that surfaces as
  # `Error running timer 'ghostel--redraw-now': (args-out-of-range N N)' when an
  # alt-screen TUI (Claude Code) resizes. 0.37 carries the fixes that close that
  # class: "Restructure Renderer invalidation", "Move term-cols/rows to
  # Renderer", "Fix rendering bug when resizing with cursor not at bottom", plus
  # the 0.35 native-race hardening. Re-derives the nixpkgs manual-package (native
  # Zig libghostty module + melpaBuild) at the bumped rev — there is no override
  # path because the upstream recipe captures the module as a `let`-binding.
  # `:defaults' already globs `lisp/*.el', so the files spec is unchanged despite
  # 0.37's lisp/ restructure. Drop this once nixpkgs advances past 0.37.
  ghostel =
    let
      pname = "ghostel";
      version = "0.37.0";
      src = pkgs.fetchFromGitHub {
        owner = "dakra";
        repo = "ghostel";
        rev = "0194b15ec957a6ce4be2ff49c4c485f648f86d0d";
        hash = "sha256-IyQhedcGp82sftgM2YXKJDgVloBLMUBDTaNO290ItB4=";
      };
      zig = pkgs.zig_0_15;
      module = pkgs.stdenv.mkDerivation (finalAttrs: {
        inherit pname version src;
        deps = zig.fetchDeps {
          inherit (finalAttrs) src pname version;
          fetchAll = true;
          hash = "sha256-CTsG3dXu3DECDbklBAtr2fYou82WNvQ1Q3JET0TmuyM=";
        };
        nativeBuildInputs = [ zig ];
        env.EMACS_INCLUDE_DIR = "${pkgs.emacs}/include";
        dontSetZigDefaultFlags = true;
        doCheck = true;
        zigCheckFlags = [
          "-Dcpu=baseline"
          "-Doptimize=ReleaseFast"
        ];
        zigBuildFlags = finalAttrs.zigCheckFlags;
        postConfigure = ''
          cp -rLT ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
          chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR/p"
        '';
      });
      libExt = pkgs.stdenv.hostPlatform.extensions.sharedLibrary;
    in
    epkgs.melpaBuild {
      inherit pname version src;
      files = ''
        (:defaults "etc" "ghostel-module${libExt}")
      '';
      preBuild = ''
        install ${module}/lib/libghostel-module${libExt} ghostel-module${libExt}
      '';
    };

  whisperx = epkgs.melpaBuild {
    pname = "whisperx";
    version = "0.1-unstable-2024-01-01";
    src = ./whisperx;
  };

  # Deep implementations lifted out of init.el into named modules (same shape as
  # whisperx/just-complete: local src, melpaBuild so autoloads are generated).
  # init.el holds only the use-package wiring; these own the logic.
  compile-ansi = epkgs.melpaBuild {
    pname = "compile-ansi";
    version = "0.1";
    src = ./compile-ansi;
    packageRequires = [ epkgs.xterm-color ];
  };

  # Desktop notifications (freedesktop D-Bus) when a backgrounded process buffer
  # blocks on input — password prompts (via comint) and a needs-input heuristic.
  # Activating the notification raises Emacs at the waiting buffer.
  proc-notify = epkgs.melpaBuild {
    pname = "proc-notify";
    version = "0.1";
    src = ./proc-notify;
    # alert is the notification router/delivery layer. consult is a soft,
    # lazily-required dependency (the pull-side `proc-notify-consult' command);
    # listed so both are on the load-path.
    packageRequires = [
      epkgs.alert
      epkgs.consult
    ];
  };

  ement-glue = epkgs.melpaBuild {
    pname = "ement-glue";
    version = "0.1";
    src = ./ement-glue;
    packageRequires = [ epkgs.ement ];
  };

  nix-system = epkgs.melpaBuild {
    pname = "nix-system";
    version = "0.1";
    src = ./nix-system;
    packageRequires = [ epkgs.transient ];
  };

  consult-omni-launch = epkgs.melpaBuild {
    pname = "consult-omni-launch";
    version = "0.1";
    src = ./consult-omni-launch;
  };

  # History-aware async-shell-command: front-loads `shell-command-history' as
  # completion candidates and marginalia-annotates each with recall's record
  # (dir/exit/duration/when). Built on consult--read for atuin-style narrowing
  # (directory/project/succeeded). recall is a soft dependency (guarded by
  # `fboundp'), so it is not listed in packageRequires.
  async-shell-history = epkgs.melpaBuild {
    pname = "async-shell-history";
    version = "0.1";
    src = ./async-shell-history;
    packageRequires = [
      epkgs.marginalia
      epkgs.consult
    ];
  };
}
