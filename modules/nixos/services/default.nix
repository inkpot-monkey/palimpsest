{
  imports = [
    ./git-annex/flake-module.nix
    ./music-sync/flake-module.nix
  ];

  flake.nixosModules = {
    # Public Service Modules
    git-annex = ./git-annex;
    # Transient rsync-over-SSH drain (slskd downloads -> beets inbox, ADR-0028).
    music-sync = ./music-sync;
    # jmap-bridge module now ships from its own repo (inputs.jmap-bridge, ADR-0016)
    # stump: upstreamed to nixpkgs (services.stump + pkgs.stump); use those directly
    dmarc-metrics-exporter = ./dmarc-metrics-exporter;
    claude-relay = ./claude-relay;
  };
}
