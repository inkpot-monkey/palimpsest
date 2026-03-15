{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.fonts;
in
{
  options.custom.profiles.fonts = {
    enable = lib.mkEnableOption "fonts configuration";
  };

  config = lib.mkIf cfg.enable {
    # Fonts
    fonts = {
      packages = with pkgs; [
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-color-emoji
        noto-fonts-monochrome-emoji
        symbola
        nerd-fonts.symbols-only
      ];
      enableDefaultPackages = true;
      fontDir.enable = true;
      fontconfig = {
        enable = true;
        antialias = true;
        defaultFonts = {
          serif = [ "Noto Serif" ];
          sansSerif = [ "Noto Sans" ];
          monospace = [ "Noto Sans Mono" ];
          emoji = [ "Noto Color Emoji" ];
        };
      };
    };
  };
}
