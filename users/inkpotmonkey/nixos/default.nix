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
      # NOTE: the gui grant's contract host-effects live in the contract (the
      # realization's display decision + input groups); inkpotmonkey's package choices
      # (the emacs overlay + the electron permit) are applied below in this binding glue
      # — the contract takes no package input (ADR-0020).

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

      # inkpotmonkey's dedicated commit-signing key rides the `signing` grant: the key is
      # provisioned in the user's home (home/signing.nix, via home sops) and home/git.nix
      # keys off hostFacts.granted.signing — not a hostName gate. The contract just carries
      # the `signing` feature; hosts grant it as data (ADR-0018, slice 13).

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
          hostFacts = inputs.contract.lib.mkHostFacts config "inkpotmonkey";
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
              # signing key rides the user's home sops, gated on the signing grant
              # (ADR-0018, slice 13). Headless/exposed hosts can't decrypt home sops,
              # so they simply don't grant it.
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
    # The gui grant's *contract* host effects are the session-union DECISION + the input
    # groups (the contract realization); the device/layout/display rendering is the host
    # gui-desktop binding. Neither can carry inkpotmonkey's package choices: the
    # emacs-unstable overlay (the contract takes no package input, ADR-0020; useGlobalPkgs
    # makes home share the system pkgs, so it must land at system level) and the Claude
    # Desktop electron permit. Both are applied here, where inkpotmonkey-gui is granted.
    (lib.mkIf config.custom.users.inkpotmonkey.granted.gui.enable {
      nixpkgs.overlays = [ inputs.emacs-overlay.overlays.default ];
      # inkpotmonkey's gui home runs Claude Desktop (electron). The permit is inkpotmonkey's
      # app choice, contributed through the contract's mergeable insecure-packages aggregator
      # (not a contract gui effect — thermo-nuclear review).
      custom.insecurePackages = [ "electron-39.8.10" ];
    })
  ];
}
