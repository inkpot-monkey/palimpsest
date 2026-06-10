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

    # Pinned to 6b30596 (Feb 2026): this rev ships the *stable* RPi vendor kernel
    # (linux_rpi-bcm2711-6.12.34-stable) which boots porcupineFish correctly. Newer revs
    # (e.g. 06c6e351) switched to the *unstable/next* kernel (6.12.87-unstable), which hangs
    # porcupineFish in the initrd before systemd (empty /var, root never grows). Do not bump
    # without re-validating a porcupineFish boot — see hosts/porcupineFish/README.md.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/6b30596bea9047a7cbb55cb58e6f8a3efa4012e2";

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

    crane = {
      url = "github:ipetkov/crane";
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
            craneLib = inputs.crane.mkLib pkgs;
          };
        };
    };
}
