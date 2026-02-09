{ inputs, ... }:
let
  # 1. Additions: Your custom packages
  additions = final: _prev: import (inputs.self + /pkgs/default.nix) final;

  # 2. Modifications: Your overrides
  modifications = {
    tree-sitter = final: prev: {
      tree-sitter = prev.tree-sitter.overrideAttrs (old: {
        passthru = old.passthru // {
          withPlugins =
            f:
            old.passthru.withPlugins (
              p:
              f (
                p
                // {
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
                }
              )
            );
        };
      });
    };
  };

  # 3. Unstable: Access to unstable channel
  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };

in
{
  inherit additions unstable-packages modifications;

  # The "Single Overlay" that combines everything
  default =
    final: prev:
    (additions final prev) // (modifications.tree-sitter final prev) // (unstable-packages final prev);
}
