{ inputs, ... }:
let
  # 1. Additions: Your custom packages
  additions =
    final: _prev:
    import (inputs.self + /pkgs/default.nix) {
      pkgs = final;
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
    # modifications.antigravity
    flexget
  ];
}
