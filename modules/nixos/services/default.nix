{
  flake.nixosModules = {
    # Public Service Modules
    git-annex = ./git-annex;
    jmap-bridge = ./jmap-bridge;
  };
}
