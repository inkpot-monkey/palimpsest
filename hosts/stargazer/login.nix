{ pkgs, ... }:
{

  # 1. Disable GNOME/GDM
  services.displayManager.gdm.enable = false;
  services.desktopManager.gnome.enable = false;

  # 2. Enable Regreet (Must be system-level)
  programs.regreet = {
    enable = true;
    settings.GTK = {
      application_prefer_dark_theme = true;
      # cursor_theme_name = "Bibata-Modern-Classic";
      icon_theme_name = "Adwaita";
      # theme_name = "Adwaita-dark";
    };
  };

  # 3. Enable Hyprland (System-level)
  programs.hyprland.enable = true;

  # 4. System dependencies for the Greeter
  environment.systemPackages = with pkgs; [
    cage
    bibata-cursors
    adwaita-icon-theme
  ];
}
