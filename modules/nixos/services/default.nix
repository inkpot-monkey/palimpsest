{
  imports = [
    ./git-annex/flake-module.nix
    ./stump/flake-module.nix
  ];

  flake.nixosModules = {
    # Public Service Modules
    git-annex = ./git-annex;
    # jmap-bridge module now ships from its own repo (inputs.jmap-bridge, ADR-0016)
    stump = ./stump;
    dmarc-metrics-exporter = ./dmarc-metrics-exporter;
    claude-relay = ./claude-relay;
  };
}
