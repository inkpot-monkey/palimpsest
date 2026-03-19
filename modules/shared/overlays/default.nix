{ inputs, ... }:
let
  # 1. Additions: Your custom packages
  additions = final: _prev: import (inputs.self + /pkgs/default.nix) final;

  # 2. Modifications: Your overrides
  modifications = {
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

    antigravity = final: prev: {
      antigravity = prev.antigravity.overrideAttrs (_: {
        version = "1.19.5";
        src = final.fetchurl {
          url = "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/1.19.5-5117559161880576/linux-x64/Antigravity.tar.gz";
          hash = "sha256-xGeNs24UwQCKGp4d3tj7jYdurqSXkmjYQF6f2Vwckm4=";
        };
      });
    };
  };

  # 4. Flexget: Fix missing WebUI assets
  flexget = import ./flexget.nix { inherit inputs; };

  # 5. Unstable: Access to unstable channel
  pkgsUnstable = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    };
  };

in
{
  inherit additions pkgsUnstable modifications;

  # The "Single Overlay" that combines everything
  default =
    final: prev:
    (additions final prev)
    // (modifications.tree-sitter final prev)
    // (modifications.antigravity final prev)
    // (flexget final prev)
    // (pkgsUnstable final prev);

}
