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

    # =========================================
    # GUI Configuration (Guarded by Profile)
    # =========================================
    (lib.mkIf config.custom.users.inkpotmonkey.granted.gui.enable {
      # uinput + the emacs overlay moved to the contract gui feature module
      # (contract/features/gui.nix). kanata moved to the host (a privileged,
      # cmd-enabled keymap is an executable payload, not a safe-set user feature) —
      # `custom.profiles.kanata` (ADR-0018, slice 11; portable kanata is issue 18).

      # The shared GUI host infrastructure (sddm + plasma6 + Wayland + default
      # session) now comes from the gui grant via contract/realization.nix, set
      # once so it composes with other gui users on the same host (ADR-0015).
      # Keep only the keyboard layout (used by Wayland compositors too).
      services.xserver.xkb = {
        layout = "gb";
        variant = "";
      };

      # The desktop hardware groups moved to contract.featureGroups.gui — they ride
      # the gui grant via the realization's clamp+grantedGroups path, instead of this
      # raw users.users write that bypassed the clamp (ADR-0018, slice 10; the
      # disk/libvirtd/qemu-libvirtd split into a virtualization feature is slice 11).

      # electron is needed by a gui app; nixpkgs.config does not merge cleanly across
      # modules (a host's value overrides), so this stays user-side until slice 11.
      nixpkgs.config.permittedInsecurePackages = [ "electron-39.8.10" ];
    })
  ];
}
