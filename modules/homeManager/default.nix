# Add your reusable home-manager modules to this directory, on their own file (https://nixos.wiki/wiki/Module).
# These should be stuff you would like to share with others, not your personal configurations.

{
  # Wire the home-manager modules' own flake-module checks. Without this the
  # git-annex home-manager VM test was defined but never run in CI — which let
  # the home init script drift from the shared logic. Keep new home modules'
  # flake-module.nix files listed here.
  imports = [
    ./git-annex/flake-module.nix
  ];

  flake.homeManagerModules = {
    # List your module files here
    finance = ./finance;
    git-annex = ./git-annex;
    kokoro-tts = ./kokoro;
    options = ./options.nix;
    # The sops binding for the contract platform interface (contract ADR-0005); imported
    # wherever sops-nix is the home secrets backend.
    platformSops = ./platform-sops.nix;
  };
}
