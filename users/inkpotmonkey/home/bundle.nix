{ inputs, ... }:

{
  imports = [
    inputs.sops-nix.homeManagerModule
    ../identity.nix

    ./base.nix
    ./shell.nix
    ./git.nix
    ./ssh.nix
    ./ai.nix
    ./dev.nix
    ./email.nix
    ./gui.nix
    ./hyprland.nix
    ./waybar.nix
    ./swaync.nix
    ./hyprlock.nix
    ./restic.nix
    ./git-annex.nix
    ./goose.nix
    ./emacs/default.nix
  ];
}
