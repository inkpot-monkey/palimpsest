{
  pkgs,
  inputs,
  lib,
  config,
  ...
}:
{
  # =========================================
  # Imports (Server)
  # =========================================
  imports = [
    inputs.sops-nix.homeManagerModule
    ../identity.nix
    ./git.nix
    ./shell.nix
    ./ssh.nix
  ];

  config = lib.mkMerge [
    {
      # =========================================
      # Home Manager Settings
      # =========================================
      programs.home-manager.enable = true;
      xdg.mimeApps.enable = lib.mkDefault false;
      home = {
        username = "inkpotmonkey";
        homeDirectory = "/home/inkpotmonkey";
        stateVersion = "25.05";

        sessionVariables = {
          SOPS_AGE_KEY_FILE = "/run/user/$(id -u)/secrets.d/age-keys.txt";
        };

        # =========================================
        # User Packages (CLI Only)
        # =========================================
        packages = with pkgs; [
          neovim
          wget
          git
          ripgrep
          fd
        ];
      };

      # =========================================
      # Sops Configuration (User)
      # =========================================
      sops.age.sshKeyPaths = [
        "/home/inkpotmonkey/.ssh/id_ed25519"
        "/etc/ssh/ssh_host_ed25519_key"
      ];

      # ================= :PROPER_PLACEMENT: =================
      systemd.user.startServices = "sd-switch";
    }

    (lib.mkIf (config.identity.profile == "gui") {
      xdg.configFile."mimeapps.list".force = true;
    })
  ];
}
