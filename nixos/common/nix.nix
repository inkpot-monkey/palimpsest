{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  nix = {
    # ---------------------------------------------------------------------
    # 1. Registry Pinning (The Speed Boost)
    # ---------------------------------------------------------------------
    # This makes `nix shell nixpkgs#...` use the same nixpkgs as your system
    registry = lib.mkForce (lib.mapAttrs (_: value: { flake = value; }) inputs);

    # Map registry inputs to legacy channels (for nix-shell/nix-env compatibility)
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;

    # ---------------------------------------------------------------------
    # 2. Garbage Collection
    # ---------------------------------------------------------------------
    gc = {
      automatic = true;
      randomizedDelaySec = "14m";
      options = "--delete-older-than 10d";
    };

    settings = {
      # ---------------------------------------------------------------------
      # 3. Features & Cleanup
      # ---------------------------------------------------------------------
      experimental-features = [
        "nix-command"
        "flakes"
        "recursive-nix"
      ];
      use-xdg-base-directories = true; # Use ~/.local/state/nix

      # Build config
      keep-outputs = true; # Prevents GC of build outputs (good for dev)
      keep-derivations = true; # REQUIRED for debugging .drv files
      auto-optimise-store = true;
      accept-flake-config = true;

      # ---------------------------------------------------------------------
      # 4. Networking & Limits (The Performance Boost)
      # ---------------------------------------------------------------------
      max-jobs = "auto";
      http-connections = 50;
      connect-timeout = 5;
      log-lines = 25;

      # Auto-GC when low on space (Free 1GB if <100MB left)
      min-free = toString (100 * 1024 * 1024);
      max-free = toString (1024 * 1024 * 1024);

      # ---------------------------------------------------------------------
      # 5. Caches & Permissions
      # ---------------------------------------------------------------------
      trusted-users = [
        "root"
        "@wheel"
      ];
      substituters = [
        "https://cache.nixos.org"
        "https://hyprland.cachix.org"
        "https://nix-community.cachix.org"
        "https://nixos-raspberrypi.cachix.org"
      ];
      trusted-public-keys = [
        "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
      ];
    };
  };
}
