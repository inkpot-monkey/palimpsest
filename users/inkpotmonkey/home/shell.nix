_: {
  programs.bash = {
    enable = true;
    historyControl = [ "erasedups" ];
    enableVteIntegration = true;
    sessionVariables = {
      PAGER = "less -X";
      LESS = "-R";
      KEYTIMEOUT = 1;
    };
  };

  programs.starship.enable = true;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.nix-index.enable = true;
}
