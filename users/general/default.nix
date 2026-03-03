{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
{
  # imports = [
  #   ./emacs
  #   ./goose.nix
  # ];

  nixpkgs.overlays = [ inputs.emacs-overlay.overlays.default ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.extraSpecialArgs = { inherit inputs; };

  home-manager.users.general = {
    sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    sops.defaultSopsFile = ../../secrets/secrets.yaml;
    imports = [
      inputs.sops-nix.homeManagerModule
      ./emacs
      ./goose.nix
    ];
    home.stateVersion = "24.05";
  };

  # 1. Create the user
  users.users.general = {
    isNormalUser = true;
    description = "general";
    extraGroups = [
      "networkmanager"
      "wheel"
    ];
    packages = with pkgs; [
      kdePackages.kate
      slack
      mpv
      protonvpn-gui
      qbittorrent
      anki
    ];
  };

  # 2. Enable specific capabilities for General's System

  # Core
  # Note: These enable options will be removed in the next steps as we refactor the modules themselves.
  # For now, we are just removing the wrapper around this user config.
  # However, since we are moving to direct imports, we should probably IMPORT the modules here
  # or in the host config. The plan says "Add explicit imports for the capabilities needed by sawtoothShark".
  # So these options will become invalid once the modules are refactored.
  # But since I am refactoring modules next, I should probably remove these options now
  # to avoid errors during the transition, OR keep them commented out until I replace them with imports
  # in the host config.
  # Actually, the plan says "Add explicit imports for the capabilities needed by sawtoothShark".
  # So the host configuration will import the capability files directly.
  # This user file should mainly define the user itself.

  environment.persistence."/persistent".users.general = {
    directories = [
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
      "/var/lib/bluetooth"
      "/etc/NetworkManager/system-connections"
      "Downloads"
      "Music"
      "Pictures"
      "Documents"
      "Videos"
      "code"
      ".gemini"
      ".antigravity"
      ".config/Antigravity"
      ".config/beekeeper-studio"
      ".config/Slack"
      ".config/sops"
      ".ssh"
      ".config/vivaldi"
      ".local/share/direnv"
      ".config/goose"
      ".local/share/goose"
      ".local/share/cass"
      ".agent"
      ".claude"
    ];
    files = [
      ".screenrc"
    ];
  };
}
