{ config, lib, ... }:
{
  imports = [
    ./gui.nix
    ./dev.nix
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
      emacs.enable = lib.mkDefault true;
      restic.enable = lib.mkDefault false;
      git-annex.enable = lib.mkDefault false;
    };
  };
}
