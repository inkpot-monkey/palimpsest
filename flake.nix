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
    # Linux build exists). Extracts the macOS app's resources, stubs the
    # macOS-native modules (@ant/claude-swift, @ant/claude-native) with a Linux
    # orchestration layer, and runs the Claude Code binary directly on the host
    # under bubblewrap — so Cowork *skills actually execute* on Linux. We
    # switched off Reginleif88/claude-cowork-nix because that fork ships only the
    # Electron shell: it never downloads the Cowork VM rootfs nor stubs the VM
    # backend, so every launch logged `rootfs.img missing` and any skill that
    # needed code execution failed (no sandbox to run in). Keep its own nixpkgs
    # pin (nixos-25.11, what the author tests). Trade-off: no real VM — skills
    # run on the host under bubblewrap, weaker isolation than the macOS VM.
    claude-cowork-linux = {
      url = "github:johnzfitch/claude-cowork-linux";
    };

    # The email bridge lives in its own repo (ADR-0017), consumed via its
    # nixosModule. Deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`: the
    # bridge's CI builds the crate against its OWN pinned nixpkgs and pushes the
    # closure to the palebluebytes cachix (trusted in nixConfig.nix). Following
    # the fleet nixpkgs would change the store hash and force a from-source Rust
    # rebuild on every bump. We consume `inputs.jmap-bridge.packages.<system>`
    # directly (see matrix/jmap-bridge.nix) so kelpy substitutes the prebuilt
    # binary instead of compiling matrix-sdk/sqlx from source.
    jmap-bridge.url = "github:palebluebytes/jmap-matrix-bridge";

    secrets = {
      url = "git+ssh://git@github.com/inkpot-monkey/stash.git";
      flake = false;
    };

    # The host↔user contract (ADR-0020): the shared schema, host-invariant realization,
    # derivation logic, and conformance kit. Now its own public repo, consumed as a
    # `github:` input — the "URL change, not a re-wire" of ADR-0015. nixpkgs follows the
    # fleet pin so there is one nixpkgs eval and no lib skew. Edit behaviour THERE, then
    # `nix flake update contract` here (the two-repo workflow of secrets/jmap-bridge).
    contract = {
      url = "github:palebluebytes/host-user-contract";
      inputs.nixpkgs.follows = "nixpkgs";
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
          };
        };
    };
}
