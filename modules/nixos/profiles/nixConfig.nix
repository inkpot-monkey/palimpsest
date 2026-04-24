{
  config,
  lib,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.nixConfig;
in
{
  options.custom.profiles.nixConfig = {
    enable = lib.mkEnableOption "Nix and global package configuration";
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
      sopsFile = inputs.secrets + "/profiles/github.yaml";
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
        keep-outputs = true;
        keep-derivations = true;
        accept-flake-config = true;
        max-jobs = "auto";
        http-connections = 50;
        connect-timeout = 5;
        log-lines = 25;

        # Auto-GC when low on space
        min-free = toString (100 * 1024 * 1024);
        max-free = toString (1024 * 1024 * 1024);

        # Substituters & Caches
        trusted-users = [
          "root"
          "@wheel"
        ];
        substituters = [
          "https://cache.nixos.org"
          "https://hyprland.cachix.org"
          "https://nix-community.cachix.org"
          "https://nixos-raspberrypi.cachix.org"
          "https://cache.numtide.com"
          "https://cache.garnix.io"
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
          "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
          "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
          "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        ];
      };
    };
  };
}
