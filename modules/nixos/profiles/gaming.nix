{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.gaming;
in
{
  options.custom.profiles.gaming = {
    enable = lib.mkEnableOption "gaming configuration (Steam, Gamemode)";
  };

  config = lib.mkIf cfg.enable {
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      extraCompatPackages = with pkgs; [
        proton-ge-bin
      ];
    };

    programs.gamemode.enable = true;
    hardware.steam-hardware.enable = true;
  };
}
