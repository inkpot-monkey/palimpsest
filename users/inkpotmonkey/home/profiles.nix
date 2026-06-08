{ config, lib, ... }:
{
  imports = [
    ./gui.nix
    ./dev.nix
    ./email.nix
    ./restic.nix
    ./git-annex.nix
    ./ai/default.nix
    ./emacs/default.nix
  ];

  config = lib.mkIf (config.identity.profile == "gui") {
    custom.home.profiles = {
      cli.enable = lib.mkDefault true; # GUI implies CLI

      gui.enable = lib.mkDefault true; # The GUI applications & config bundle
      dev.enable = lib.mkDefault true;
      ai.enable = lib.mkDefault true;
      email.enable = lib.mkDefault false;
      emacs.enable = lib.mkDefault true;
      restic.enable = lib.mkDefault false;
      git-annex.enable = lib.mkDefault false;
    };
  };
}
