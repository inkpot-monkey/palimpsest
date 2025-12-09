{
  description = "I am config and my code is a string that will be run.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/staging-next";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    impermanence.url = "github:nix-community/impermanence";

    nixos-hardware.url = "github:nixos/nixos-hardware";

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

    antigravity-nix = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    tree-sitter-astro = {
      url = "github:virchau13/tree-sitter-astro";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      ...
    }:
    let
      utils = import ./utils { lib = nixpkgs.lib; };
      inherit (utils) importTemplates importHomes;
    in
    flake-parts.lib.mkFlake { inherit inputs; } (
      { self, ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
        ];

        perSystem =
          {
            config,
            self',
            inputs',
            pkgs,
            system,
            ...
          }:
          {
            # Your custom packages
            # Accessible through 'nix build', 'nix shell', etc
            packages = import ./pkgs pkgs;

            # Devshell for bootstrapping
            # Accessible through 'nix develop' or 'nix-shell' (legacy)
            devShells = import ./shell.nix { inherit inputs pkgs system; };

            checks = {
              git-annex = pkgs.callPackage ./modules/nixos/git-annex/tests/git-annex.nix { };
              git-annex-stateless = pkgs.callPackage ./modules/nixos/git-annex/tests/git-annex-stateless.nix { };
              git-annex-hybrid = pkgs.callPackage ./modules/nixos/git-annex/tests/git-annex-hybrid.nix { };
              git-annex-encryption = pkgs.callPackage ./modules/nixos/git-annex/tests/git-annex-encryption.nix { };
            };
          };

        flake = {
          # Your custom packages and modifications, exported as overlays
          overlays = import ./overlays { inherit inputs; };
          # Reusable nixos modules you might want to export
          # These are usually stuff you would upstream into nixpkgs
          nixosModules = import ./modules/nixos;
          # Reusable home-manager modules you might want to export
          # These are usually stuff you would upstream into home-manager
          homeManagerModules = import ./modules/home-manager;

          # NixOS configuration entrypoint
          # Available through 'nixos-rebuild --flake .#your-hostname'
          nixosConfigurations = {
            stargazer = nixpkgs.lib.nixosSystem {
              specialArgs = {
                inherit inputs self;
                outputs = self;
                residents = [ self.homeConfigurations.inkpotmonkey ];
              };

              modules = [
                # > Our main nixos configuration file <
                ./nixos/stargazer/configuration.nix
              ];
            };

            porcupineFish = nixpkgs.lib.nixosSystem {
              system = "aarch64-linux";
              modules = [ ./nixos/porcupineFish/configuration.nix ];
              specialArgs = {
                inherit inputs self;
                outputs = self;
              };
            };

            # nixos-rebuild --target-host root@37.205.14.206 switch --flake .#kelpy
            kelpy = nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              specialArgs = {
                inherit inputs nixpkgs self;
                outputs = self;
                settings = {
                  admin = {
                    email = "thomas@palebluebytes.xyz";
                  };
                  host = {
                    ip4 = "37.205.14.206";
                    ip6 = "2a03:3b40:fe:896::1";
                    hostName = "kelpy";
                    domain = "palebluebytes.space";
                  };
                };
              };
              modules = [
                ./nixos/kelpy/configuration.nix
              ];
            };

            # nixos-rebuild --target-host <tbd>@<tbd> switch --flake .#potbelliedSeahorse
            potbelliedSeahorse = nixpkgs.lib.nixosSystem {
              system = "aarch64-linux";
              modules = [ ./nixos/potbelliedSeahorse/configuration.nix ];
              specialArgs = {
                inherit inputs self;
                outputs = self;
              };
            };
          };

          images.porcupineFish = self.nixosConfigurations.porcupineFish.config.system.build.sdImage;

          # Home-manager configuration entrypoint
          # Each home is an attribute set with 2 values defined in a directory <root>/users/<username>/home.nix
          # 1. settings = values for the nixosConfiguration
          # 2. home = a function which is the input for the home-manager nixosModule
          homeConfigurations = importHomes;

          # This operates under the assumption that all templates are stored
          # in the directory <root>/templates
          templates = importTemplates;
        };
      }
    );
}
