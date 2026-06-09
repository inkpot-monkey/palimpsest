{
  pkgs,
  lib,
  config,
  ...
}:
{
  options.custom.home.profiles.base = {
    enable = lib.mkEnableOption "base home-manager configuration";
  };

  config = lib.mkIf config.custom.home.profiles.base.enable {

    # =========================================
    # Home Manager Settings
    # =========================================
    programs.home-manager.enable = true;
    xdg.mimeApps.enable = lib.mkDefault false;

    home = {
      inherit (config.identity) username;
      homeDirectory = "/home/${config.identity.username}";
      # stateVersion must be <= the home-manager release. Most hosts run unstable
      # HM ("26.11"); the pi hosts pin home-manager-25_11, whose newest accepted
      # value is "25.11". `lib.version` reflects the system nixpkgs of each host.
      stateVersion = if lib.versionAtLeast lib.version "26.05" then "26.11" else "25.11";

      sessionVariables = {
        SOPS_AGE_KEY_FILE = "/run/user/$(id -u)/secrets.d/age-keys.txt";
      };

      # =========================================
      # User Packages (Global)
      # =========================================
      packages = with pkgs; [
        neovim # Primary editor fallback
      ];
    };

    # =========================================
    # Sops Configuration (User)
    # =========================================
    sops.age.sshKeyPaths = [
      "${config.home.homeDirectory}/.ssh/id_ed25519"
      # "/etc/ssh/ssh_host_ed25519_key"
    ];

    # ================= :PROPER_PLACEMENT: =================
    systemd.user.startServices = "sd-switch";

  };
}
