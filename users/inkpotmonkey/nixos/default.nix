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
      nixpkgs.overlays = [ inputs.emacs-overlay.overlays.default ];

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

      # inkpotmonkey's dedicated commit-signing key (a NON-admin ed25519 key; see
      # users/inkpotmonkey/home/git.nix for why identity.sshKey must not be used).
      # Distributed at the SYSTEM level because headless hosts (e.g. kelpy, which
      # runs the aionui agent with no user session) have no working per-user
      # home-manager sops. Deployed only on hosts whose host key is a recipient of
      # users/inkpotmonkey.yaml; git.nix keys off the presence of this secret and
      # falls back to ~/.ssh elsewhere.
      sops.secrets.inkpotmonkey_signing_key =
        lib.mkIf
          (builtins.elem config.networking.hostName [
            "kelpy"
            "stargazer"
            "sawtoothShark"
          ])
          {
            sopsFile = self.lib.getSecretPath "users/inkpotmonkey.yaml";
            key = "signing_key";
            owner = "inkpotmonkey";
            mode = "0400";
          };

      # =========================================
      # Home Manager Configuration
      # =========================================
      home-manager = {
        useUserPackages = true;
        useGlobalPkgs = true;
        extraSpecialArgs = {
          inherit
            inputs
            self
            ;
        };
        backupFileExtension = "hm-backup";
        users.inkpotmonkey =
          { osConfig, ... }:
          let
            inherit (osConfig.custom.users.inkpotmonkey) identity;
          in
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
              gui.enable = osConfig.custom.users.inkpotmonkey.granted.gui.enable;
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
      hardware.uinput.enable = true;
      services.kanata = {
        enable = true;
        package = pkgs.kanata-with-cmd;
        keyboards.default = {
          configFile = ../home/configs/kanata.kbd;
          extraDefCfg = "process-unmapped-keys yes";
        };
      };

      systemd.services.kanata-default = {
        path = [ pkgs.brightnessctl ];
        serviceConfig.SupplementaryGroups = [
          "input"
          "uinput"
          "video"
        ];
      };

      # 2. KDE Plasma 6 (Wayland Only)
      services = {
        xserver.enable = false; # Disable X11 server
        displayManager = {
          sddm = {
            enable = lib.mkDefault true;
            wayland.enable = true;
          };
          defaultSession = "plasma";
        };
        desktopManager.plasma6.enable = true;
      };

      # Still define XKB settings as they are used by Wayland compositors
      services.xserver.xkb = {
        layout = "gb";
        variant = "";
      };

      users.users.inkpotmonkey = {
        extraGroups = [
          "input"
          "uinput"
          # For zsa keyboard
          "plugdev"
          "disk"
          "qemu-libvirtd"
          "dialout"
          "libvirtd"
        ];
      };

      nixpkgs.config.permittedInsecurePackages = [ "electron-39.8.10" ];
    })
  ];
}
