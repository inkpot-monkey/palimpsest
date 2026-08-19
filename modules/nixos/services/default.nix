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
    # stump: the module is upstream (services.stump); use it directly. `pkgs.stump`
    # is TEMPORARILY overridden to 0.1.6 in pkgs/stump (#111) — see the removal
    # condition there; the option is unaffected either way.
    dmarc-metrics-exporter = ./dmarc-metrics-exporter;
    claude-relay = ./claude-relay;
  };
}
