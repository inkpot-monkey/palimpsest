{
  pkgs,
  lib,
  config,
  inputs,
  self,
  homeManagerInput,
  ...
}:
{
  imports = [
    homeManagerInput.nixosModules.home-manager
  ];

  config = lib.mkMerge [
    {
      # NOTE: the emacs overlay moved to the contract gui feature module
      # (contract/features/gui.nix) — it rides the gui grant there, so the user no
      # longer writes it (ADR-0018, slice 10).

      # 1. User shell and keys
      custom.users.inkpotmonkey.identity.trustedKeys =
        let
          keyDir = ../keys;
          # Read all .pub files in the keys directory
          keyFiles =
            if builtins.pathExists keyDir then
              lib.filter (lib.hasSuffix ".pub") (lib.attrNames (builtins.readDir keyDir))
            else
              [ ];
        in
        map (file: builtins.readFile (keyDir + "/${file}")) keyFiles;

      users.users.inkpotmonkey.shell = pkgs.bash;

      # inkpotmonkey's dedicated commit-signing key now rides the `signing` grant via
      # the contract signing feature module (contract/features/signing.nix), instead of
      # a hostName ∈ {…} gate here. Hosts grant signing as data; git.nix keys off
      # hostFacts.granted.signing (ADR-0018, slice 13).

      # =========================================
      # Home Manager Configuration
      # =========================================
      home-manager = {
        useUserPackages = true;
        useGlobalPkgs = true;
        extraSpecialArgs = {
          inherit inputs self;
          # The home reads host state ONLY through this restricted projection, never
          # raw osConfig (ADR-0018, slice 12). The user's own identity is pushed in the
          # same way — both computed from the system config here, in the wiring, not
          # reached for inside a home module.
          hostFacts = self.lib.mkHostFacts config "inkpotmonkey";
          inherit (config.custom.users.inkpotmonkey) identity;
        };
        backupFileExtension = "hm-backup";
        users.inkpotmonkey =
          { hostFacts, identity, ... }:
          {

            imports = [
              ../home/default.nix
              self.homeManagerModules.options
              inputs.nix-index-database.homeModules.nix-index
            ];

            # Explicitly pass the system identity to Home Manager user
            inherit identity;

            # =========================================
            # Enable Home Manager Profiles
            # =========================================
            custom.home.profiles = {
              cli.enable = true;
              gui.enable = hostFacts.granted.gui.enable;
              restic.enable = hostFacts.granted.restic.enable;
              # signing key rides the user's home sops (like restic), gated on the
              # signing grant (ADR-0018, slice 13). Headless/exposed hosts can't
              # decrypt home sops, so they simply don't grant it.
              signing.enable = hostFacts.granted.signing.enable;
            };
          };
      };

      # Fix for XDG Desktop Portal with home-manager.useUserPackages
      environment.pathsToLink = [
        "/share/xdg-desktop-portal"
        "/share/applications"
      ];
    }
    # All host effects of the gui grant — display surface, hardware groups, uinput,
    # the emacs overlay, the host keyboard layout, and the electron permit — now live
    # in the contract (realization + contract/features/gui.nix), so this user module
    # writes no gui host config at all. That is the point of the feature module: the
    # contract acts on the host's behalf, the user never does (ADR-0018, slices 10-11).
  ];
}
