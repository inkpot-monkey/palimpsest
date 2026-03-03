{ pkgs, ... }:

{
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
}
