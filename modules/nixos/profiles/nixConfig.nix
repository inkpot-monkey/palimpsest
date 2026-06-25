{
  config,
  lib,
  inputs,
  self,
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
      sopsFile = self.lib.getSecretFile "github";
      # Group-readable by the human user so their git can authenticate to GitHub
      # over HTTPS via the credential helper in users/inkpotmonkey/home/git.nix
      # (needed by headless agent services on kelpy — e.g. the Claude relay's
      # `claude` sessions — which have no user session and thus no home-manager
      # sops secrets). Root/nix-daemon still reads it for `access-tokens`.
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
