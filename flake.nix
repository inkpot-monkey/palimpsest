{
  description = "I am config and my code is a string that will be run.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-25_11 = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixos-raspberrypi/nixpkgs";
    };

    # Pinned to 40861a6 (Mar 2026): this rev's DEFAULT is the *stable*-branch RPi vendor
    # kernel linux_rpi-bcm2711-6.12.47-stable (+ matched firmware 1.20250915), both cached
    # on nixos-raspberrypi.cachix.org (no local kernel compile). Stay on a *stable*-branch
    # kernel: the *unstable/next* branch (e.g. 6.12.87 on rev 06c6e351, or 6.18.x on the
    # develop branch) hangs porcupineFish in the initrd before systemd (empty /var, root
    # never grows). Only bump to another rev whose default is a newer *stable* kernel, and
    # re-validate a porcupineFish boot — see hosts/porcupineFish/README.md.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/40861a63b4162f9332d03e125d76b9b8e2bbe79c";

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:nixos/nixos-hardware";

    nixos-turing-rk1.url = "github:GiyoMoon/nixos-turing-rk1";

    emacs-overlay.url = "github:nix-community/emacs-overlay";

    vpsFree.url = "github:vpsfreecz/vpsadminos";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    openclaw-nix = {
      url = "github:openclaw/nix-openclaw";
    };

    # Community repackaging of the Claude Desktop app for Linux (no official
    # Linux build exists). Extracts the Windows app's resources and rebuilds a
    # native Electron app, with Cowork support. Actively maintained fork of the
    # original k3d3 flake — tracks current Claude Desktop versions and vendors
    # its own asar tool (the upstream's `nodePackages.asar` was removed from
    # nixpkgs on 2026-03-03). Keep its own nixpkgs pin (what the author tests).
    claude-desktop = {
      url = "github:Reginleif88/claude-cowork-nix";
    };

    # The email bridge lives in its own repo (ADR-0017), consumed via its overlay
    # (adds pkgs.jmap-matrix-bridge) + nixosModule. Its nixpkgs follows ours so
    # the crate builds against the fleet pin.
    jmap-bridge = {
      url = "github:palebluebytes/jmap-matrix-bridge";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    secrets = {
      url = "git+ssh://git@github.com/inkpot-monkey/stash.git";
      flake = false;
    };

  };

  outputs =
    inputs@{
      self,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks.flakeModule
        ./parts/settings.nix
        ./parts/shells.nix
        ./parts/git-hooks.nix
        ./parts/apps
        ./parts/checks
        ./lib
        ./contract
        ./users
        ./hosts
        ./modules/nixos/services
        ./modules/nixos/profiles
        ./modules/homeManager
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        {
          _module.args.pkgs = self.lib.mkPkgs system;
          formatter = pkgs.nixfmt;
          packages = import ./pkgs {
            inherit pkgs;
          };
        };
    };
}
