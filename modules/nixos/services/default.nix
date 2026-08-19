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
    # stump: the module is upstream (services.stump); use it directly, on nixpkgs'
    # own `pkgs.stump`.
    dmarc-metrics-exporter = ./dmarc-metrics-exporter;
    claude-relay = ./claude-relay;
  };
}
