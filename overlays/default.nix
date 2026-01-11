# Custom overlays for modifying packages
{ inputs, ... }:
{
  # Import custom packages from 'pkgs' directory
  additions = final: _prev: (import ../pkgs final) // {
    kokoros = final.callPackage ../pkgs/kokoros { };
  };

  # Custom package modifications
  modifications = final: prev: {
    tree-sitter = prev.tree-sitter.overrideAttrs (old: {
      passthru = old.passthru // {
        withPlugins =
          f:
          old.passthru.withPlugins (
            p:
            f (
              p
              // {

                # Define your custom grammars here neatly
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

  unstable-packages = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      system = final.stdenv.hostPlatform.system;
      config.allowUnfree = true;
    };
  };

}
