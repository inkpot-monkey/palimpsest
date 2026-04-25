{ config, lib, ... }:
{
  imports = [
    ./gui-base.nix
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

  config = lib.mkIf (config.identity.profile == "gui") {
    custom.home.profiles = {
      cli.enable = lib.mkDefault true; # GUI implies CLI

      gui-base.enable = lib.mkDefault true; # The atomic GUI profile
      dev.enable = lib.mkDefault true;
      ai.enable = lib.mkDefault true;
      goose.enable = lib.mkDefault true;
      hyprland.enable = lib.mkDefault true;
      waybar.enable = lib.mkDefault true;
      swaync.enable = lib.mkDefault true;
      hyprlock.enable = lib.mkDefault true;
      email.enable = lib.mkDefault false;
      emacs.enable = lib.mkDefault true;
      restic.enable = lib.mkDefault true;
      git-annex.enable = lib.mkDefault true;
    };
  };
}
