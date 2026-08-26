{
  config,
  lib,
  inputs,
  self,
  settings ? null,
  ...
}:

let
  cfg = config.custom.profiles.nixConfig;

  # The host's declared minimum headroom, from the fleet registry (parts/settings.nix).
  # Guarded so this profile still evaluates standalone, where no settings are threaded in.
  declaredFloor =
    if settings != null then
      (settings.nodes.${config.networking.hostName}.diskFloorGiB or null)
    else
      null;
in
{
  options.custom.profiles.nixConfig = {
    enable = lib.mkEnableOption "Nix and global package configuration";

    # The daemon's mid-build emergency GC, in GiB. It is the only thing standing between a
    # long build and a full store filesystem — the weekly `gc` timer below is far too coarse
    # to catch a store that fills in an afternoon. It MUST be scaled to the host's store
    # rather than set fleet-wide: the floor has to sit comfortably below a host's steady-state
    # free space or the daemon collects on every single build.
    #
    # The number comes from the fleet registry's `diskFloorGiB` (parts/settings.nix), which
    # is where it is measured and justified (ADR-0032). Deliberately the SAME number the disk-space
    # watcher alerts on, so "the host must never have less than X free" is declared once and
    # both defended (here) and reported on (monitoring/disk-space.nix) — they cannot drift
    # into disagreeing about what counts as dangerously full.
    freeSpaceFloor = lib.mkOption {
      type = lib.types.ints.positive;
      default = if declaredFloor != null then declaredFloor else 5;
      defaultText = lib.literalExpression "settings.nodes.\${hostName}.diskFloorGiB, else 5";
      description = "GiB of free space below which the nix daemon starts collecting mid-build.";
    };

    freeSpaceCeiling = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "GiB of free space the daemon collects up to once the floor is breached.";
    };
  };

  config = lib.mkIf cfg.enable {
    # =========================================
    # Nix & Global Package Configuration
    # =========================================
    nixpkgs.config.allowUnfree = true;
    programs.nh = {
      enable = true;
      flake = "/home/inkpotmonkey/code/nixos";
    };

    sops.secrets.github_token = {
      sopsFile = self.lib.getSecretFile "github";
      # Group-readable by the human user so their git can authenticate to GitHub
      # over HTTPS via the credential helper in users/inkpotmonkey/home/git.nix
      # (needed by headless services on kelpy that run as the user but have no user
      # session, and thus no home-manager sops secrets). Root/nix-daemon still reads
      # it for `access-tokens`.
      mode = "0440";
      group = "users";
    };

    sops.templates."nix-github-token".content = ''
      access-tokens = github.com=${config.sops.placeholder.github_token}
    '';

    nix = {
      extraOptions = ''
        !include ${config.sops.templates."nix-github-token".path}
      '';

      # Registry Pinning (The Speed Boost)
      registry = lib.mkForce (lib.mapAttrs (_: value: { flake = value; }) inputs);

      # Map registry inputs to legacy channels
      nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;

      # Garbage Collection
      gc = {
        automatic = true;
        dates = "weekly";
        options = "--delete-older-than 30d";
      };

      settings = {
        # Features
        experimental-features = [
          "nix-command"
          "flakes"
        ]
        ++ lib.optional (!config.custom.profiles.pi.enable or false) "recursive-nix";
        use-xdg-base-directories = true;

        # Performance & Optimization
        auto-optimise-store = true;
        # Both deliberately OFF. Together they form a retention loop that no `gc` policy can
        # break: a live output keeps its .drv (keep-derivations), which keeps the outputs of
        # every one of its inputs (keep-outputs), which keep *their* .drvs, and so on — so the
        # complete build graph of everything ever built and still rooted stays alive, not just
        # what is runtime-reachable. Measured on sawtoothShark with them on: 214,298 store
        # paths of which 170,028 were .drv files, against a runtime-reachable set of 28,981
        # paths — ~49 GiB held by the build graph alone, and only 10 GiB actually collectable.
        # The payoff they buy (not re-fetching sources when rebuilding a derivation you have
        # already built) is not worth that on any host here, least of all the small-store Pis.
        keep-outputs = false;
        keep-derivations = false;
        accept-flake-config = true;
        max-jobs = "auto";
        http-connections = 50;
        connect-timeout = 5;
        log-lines = 25;

        # Auto-GC when low on space (see freeSpaceFloor/freeSpaceCeiling above)
        min-free = toString (cfg.freeSpaceFloor * 1024 * 1024 * 1024);
        max-free = toString (cfg.freeSpaceCeiling * 1024 * 1024 * 1024);

        narinfo-cache-positive-ttl = 3600;

        # Substituters & Caches
        trusted-users = [
          "root"
          "@wheel"
        ];
        substituters = [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
          "https://nixos-raspberrypi.cachix.org"
          "https://cache.numtide.com"
          # Prebuilt jmap-matrix-bridge crate closure (pushed by its CI). Lets the
          # fleet substitute the Rust build instead of compiling from source — see
          # the jmap-bridge input (no `nixpkgs.follows`, so the closure matches CI).
          "https://palebluebytes.cachix.org"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
          "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
          "palebluebytes.cachix.org-1:LzASburC4RYH9jQaOwB9r4heDPYWTbdA54XPMsLMeDc="
        ];
      };
    };
  };
}
