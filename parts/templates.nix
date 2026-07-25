# Flake template outputs (ADR / wayfinder #103). `templates` is a
# system-independent top-level output, so it lives on `flake.*`, not
# `perSystem` — mirroring `flake.settings`, `flake.overlays`, `flake.lib`.
#
# The scaffold at templates/web-starter/ carries its OWN nested flake.nix,
# quality gate, and prettier config. That nested flake is inert: the parent
# never imports it, and `nix flake check` validates only this attrset's shape
# (path exists, description is a string) without recursing. So there is zero
# fleet eval / build cost. See parts/treefmt.nix for the matching exclude that
# keeps the fleet formatter off the scaffold's own conventions.
#
# Consume with: nix flake init -t github:inkpot-monkey/palimpsest#web-starter
{
  flake.templates.web-starter = {
    path = ../templates/web-starter;
    description = "Astro static-first website starter (Cloudflare Pages, vanilla-CSS design tokens, Playwright)";
    welcomeText = ''
      # web-starter

      A static-first Astro site: vanilla-CSS design tokens, self-hosted fonts,
      a Nix dev shell, and a pre-push quality gate.

      Next steps:
      1. `direnv allow` (or `nix develop`) to enter the dev shell.
      2. `pnpm install`
      3. `pnpm dev`

      Read `README.md` for the how-I-build-websites guide and
      `CODING_STANDARDS.md` for the rulebook.
    '';
  };
}
