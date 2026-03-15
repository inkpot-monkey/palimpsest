{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.regreet;
in
{
  options.custom.profiles.regreet = {
    enable = lib.mkEnableOption "ReGreet greeter (DM) configuration";
  };

  config = lib.mkIf cfg.enable {
    programs.regreet = {
      enable = true;
      settings.GTK = {
        application_prefer_dark_theme = true;
        icon_theme_name = "Adwaita";
      };
    };

    environment.systemPackages = with pkgs; [
      cage
      bibata-cursors
      adwaita-icon-theme
    ];
  };
}
