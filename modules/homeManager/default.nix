# Add your reusable home-manager modules to this directory, on their own file (https://nixos.wiki/wiki/Module).
# These should be stuff you would like to share with others, not your personal configurations.

{
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
