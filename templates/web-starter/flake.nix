{
  description = "Astro static-first website (Cloudflare Pages, vanilla-CSS design tokens).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks.flakeModule
        inputs.treefmt-nix.flakeModule
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem =
        { config, pkgs, ... }:
        {
          # `nix fmt` and the pre-push hook run treefmt over this flake's own
          # Nix: nixfmt + statix + deadnix. Prettier / ESLint / Stylelint own the
          # web side and run from the project's pnpm toolchain (see the pre-push
          # hooks below) so prettier-plugin-astro and the type-aware ESLint rules
          # resolve from node_modules. See CODING_STANDARDS.md for the full gate.
          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              statix.enable = true;
              deadnix.enable = true;
            };
            # deadnix/statix rewrite, then nixfmt cleans up after them.
            settings.formatter.deadnix.priority = 1;
            settings.formatter.statix.priority = 2;
            settings.formatter.nixfmt.priority = 3;
          };

          # The single quality gate. Every hook fires at PRE-PUSH — nothing at
          # pre-commit — so commits stay fast and the remote stays clean (#101).
          # Chain order mirrors CODING_STANDARDS.md: format → lint → type → test.
          pre-commit.settings = {
            default_stages = [ "pre-push" ];
            hooks = {
              treefmt = {
                enable = true;
                package = config.treefmt.build.wrapper;
                stages = [ "pre-push" ];
              };
              prettier = {
                enable = true;
                entry = "pnpm exec prettier --check .";
                language = "system";
                pass_filenames = false;
                stages = [ "pre-push" ];
              };
              eslint = {
                enable = true;
                entry = "pnpm exec eslint .";
                language = "system";
                pass_filenames = false;
                stages = [ "pre-push" ];
              };
              stylelint = {
                enable = true;
                entry = ''pnpm exec stylelint "src/**/*.{css,astro}"'';
                language = "system";
                pass_filenames = false;
                stages = [ "pre-push" ];
              };
              astro-check = {
                enable = true;
                entry = "pnpm exec astro check";
                language = "system";
                pass_filenames = false;
                stages = [ "pre-push" ];
              };
              vitest = {
                enable = true;
                entry = "pnpm exec vitest run";
                language = "system";
                pass_filenames = false;
                stages = [ "pre-push" ];
              };
            };
          };

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [
              nodejs_24
              pnpm

              # Language servers for editor tooling.
              nil
              nixfmt-rfc-style
              typescript-language-server
              vscode-langservers-extracted

              # Playwright drives the system Chromium — its bundled browsers
              # don't run on NixOS. See playwright.config.ts.
              chromium
            ];

            # Playwright: never download browsers; point it at the Nix Chromium.
            PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
            PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH = "${pkgs.chromium}/bin/chromium";

            shellHook = ''
              ${config.pre-commit.installationScript}
              echo "web-starter — run: pnpm install && pnpm dev"
            '';
          };
        };
    };
}
