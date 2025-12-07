# Custom overlays for modifying packages
{ inputs, ... }:
{
  # Import custom packages from 'pkgs' directory
  additions = final: _prev: import ../pkgs final;

  # Custom package modifications
  modifications = final: prev: {
    tree-sitter = final.unstable.tree-sitter.override {
      extraGrammars = {
        tree-sitter-astro = {
          src = inputs.tree-sitter-astro.outPath;
        };
      };
    };
  };

  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  };

}
