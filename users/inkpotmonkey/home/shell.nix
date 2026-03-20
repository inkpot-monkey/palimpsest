{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.custom.home.profiles.shell = {
    enable = lib.mkEnableOption "shell configuration";
  };

  config = lib.mkIf config.custom.home.profiles.shell.enable {
    programs.bash = {
      enable = true;
      historyControl = [ "erasedups" ];
      enableVteIntegration = true;
      sessionVariables = {
        PAGER = "less -X";
        LESS = "-R";
        KEYTIMEOUT = 1;
        NOM = "0";
      };
    };

    programs.starship.enable = true;

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    programs.nix-index.enable = true;

    home.packages = with pkgs; [
      ripgrep
      fd
      jq
    ];
  };
}
