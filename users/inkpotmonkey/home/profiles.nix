{ config, lib, ... }:
{
  imports = [
    ./gui.nix
    ./ai.nix
    ./dev.nix
    ./goose.nix
    ./email.nix
    ./hyprland.nix
    ./waybar.nix
    ./swaync.nix
    ./hyprlock.nix
    ./restic.nix
    ./git-annex.nix
    ./emacs/default.nix
  ];

  config = lib.mkIf config.custom.home.profiles.gui.enable {
    custom.home.profiles = {
      cli.enable = lib.mkDefault true; # GUI implies CLI

      gui.enable = lib.mkDefault true;      # The GUI applications & config bundle
      dev.enable = lib.mkDefault true;
      ai.enable = lib.mkDefault true;
      goose.enable = lib.mkDefault false;
      hyprland.enable = lib.mkDefault false;
      waybar.enable = lib.mkDefault false;
      swaync.enable = lib.mkDefault false;
      hyprlock.enable = lib.mkDefault false;
      email.enable = lib.mkDefault false;
      emacs.enable = lib.mkDefault true;
      restic.enable = lib.mkDefault false;
      git-annex.enable = lib.mkDefault false;
    };
  };
}
