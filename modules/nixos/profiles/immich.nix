{
  config,
  lib,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.immich;
in
{
  options.custom.profiles.immich = {
    enable = lib.mkEnableOption "Immich photo library";

    machineLearning = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run Immich's machine-learning worker (face/object/CLIP search).

        On by default because search is most of why Immich beats a directory of
        JPEGs. It is the expensive half: the worker downloads its models on first
        run and holds them resident, so turn it off on a node where RAM is the
        binding constraint and you only want the timeline.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.immich = {
      enable = true;
      # Loopback only. Caddy fronts it from the service registry
      # (parts/settings.nix → services.private.immich) with the internal_only
      # tailnet guard, so the port must never be reachable off-host.
      host = "127.0.0.1";
      inherit (settings.services.private.immich) port;
      openFirewall = false;

      machine-learning.enable = cfg.machineLearning;

      # The module provisions postgres itself (createDB) and needs a vector
      # index extension for CLIP search. VectorChord is the current upstream
      # default; leaving both toggles at their module defaults keeps us on
      # whatever the pinned nixpkgs considers supported, which is the half that
      # breaks across major Immich bumps.
      database.enable = true;
    };

    # Immich stores originals, thumbnails and encoded video under mediaLocation,
    # and its postgres lives in the usual state dir. Both must survive a reboot on
    # an impermanent host — losing the DB loses albums, faces and share links even
    # though the originals are still on disk.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        config.services.immich.mediaLocation
        "/var/lib/postgresql"
      ];
    };
  };
}
