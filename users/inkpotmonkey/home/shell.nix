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
      # Keep a deep, persistent history. home-manager already points HISTFILE at
      # ~/.bash_history and sets `shopt -s histappend'.
      historySize = 50000;
      historyFileSize = 500000;
      enableVteIntegration = true;
      # Forward-capture: flush every command to HISTFILE as it runs (not just on
      # a clean shell exit) so long-lived ghostel/ssh sessions actually record,
      # and the file is readable in real time by Emacs `chelys-galactica' and by
      # tooling. Timestamp each entry (parity with recall). Prepend to any
      # existing PROMPT_COMMAND (e.g. the VTE integration) rather than clobber it.
      initExtra = ''
        HISTTIMEFORMAT="%F %T "
        PROMPT_COMMAND="history -a''${PROMPT_COMMAND:+; ''${PROMPT_COMMAND}}"
      '';
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
      # Core Utilities
      ripgrep
      fd
      jq
      wget
      tree
      git
    ];
  };
}
