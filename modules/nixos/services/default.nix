{
  imports = [
    ./git-annex/flake-module.nix
    ./stump/flake-module.nix
  ];

  flake.nixosModules = {
    # Public Service Modules
    git-annex = ./git-annex;
    jmap-bridge = ./jmap-bridge;
    stump = ./stump;
  };
}
