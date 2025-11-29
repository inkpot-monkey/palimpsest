{
  pkgs,
  config,
  lib,
  self,
  ...
}:

{
  programs.emacs = {
    enable = true;
    package = pkgs.emacs-pgtk;
    extraPackages = epkgs: [
      epkgs.vterm
      epkgs.treesit-grammars.with-all-grammars
    ];
  };

  services.emacs = {
    enable = true;
    package = config.programs.emacs.finalPackage;
  };

  # Emacs configuration
  xdg.configFile = {
    "emacs/init.el" = {
      text =
        builtins.replaceStrings
          [ "@sops-file@" "@username@" "@email@" "@treesit-grammars@" ]
          [
            "${self.outPath}/secrets/secrets.yaml"
            "inkpot-monkey"
            "inkpot-monkey@palebluebytes.space"
            "${pkgs.emacsPackages.treesit-grammars.with-all-grammars}"
          ]
          (builtins.readFile ./init.el);
    };
    "emacs/early-init.el" = {
      source = ./early-init.el;
    };
  };

  # doesnt work only tests before the new build
  # home.activation = {
  #   installEmacsConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  #     ${config.programs.emacs.finalPackage}/bin/emacs --batch -l ${config.xdg.configHome}/emacs/init.el
  #   '';
  # };

  services.gpg-agent = {
    pinentry.package = config.programs.emacs.finalPackage;
    extraConfig = ''
      allow-emacs-pinentry
      allow-loopback-pinentry
    '';
  };

  home.packages = with pkgs; [
    binutils

    ## Dependencies
    zip
    cmake
    ripgrep
    aspell
    aspellDicts.en
    aspellDicts.en-computers
    aspellDicts.en-science
    sops

    # :tools editorconfig
    editorconfig-core-c
    # :tools lookup & :lang org +roam
    sqlite
    # :lang latex & :lang org (latex previews)
    texlive.combined.scheme-medium

    # formatter
    prettier

    # LSPs
    nil
    nixfmt-rfc-style
    shfmt
    shellcheck
    nodePackages.bash-language-server
    dockerfile-language-server
    nodePackages.typescript-language-server
    nodePackages.yaml-language-server
    vscode-langservers-extracted # html, css, json, eslint
    taplo # toml

    # :lang python
    python3
    black
    pyright

    # :lang javascript
    nodejs_24

    # :lang markdown
    pandoc

    # :lang web
    html-tidy
    stylelint
    jsbeautifier

  ];

  programs.bash.bashrcExtra = ''
    vterm_printf() {
        if [ -n "$TMUX" ] && ([ "''${TERM%%-*}" = "tmux" ] || [ "''${TERM%%-*}" = "screen" ]); then
            # Tell tmux to pass the escape sequences through
            printf "\ePtmux;\e\e]%s\007\e\\" "$1"
        elif [ "''${TERM%%-*}" = "screen" ]; then
            # GNU screen (screen, screen-256color, screen-256color-bce)
            printf "\eP\e]%s\007\e\\" "$1"
        else
            printf "\e]%s\e\\" "$1"
        fi
    }

        if [ "$INSIDE_EMACS" = 'vterm' ]; then
          clear() {
            vterm_printf "51;Evterm-clear-scrollback";
            tput clear;
          }
        fi

        PROMPT_COMMAND="''${PROMPT_COMMAND:+$PROMPT_COMMAND; }"'echo -ne "\033]0;''${HOSTNAME}:''${PWD}\007"'

        vterm_prompt_end(){
          vterm_printf "51;A$(whoami)@$(hostname):$(pwd)"
        }
        PS1=$PS1'\[$(vterm_prompt_end)\]'

        vterm_cmd() {
          local vterm_elisp
          vterm_elisp=""
          while [ $# -gt 0 ]; do
            vterm_elisp="$vterm_elisp""$(printf '"%s" ' "$(printf "%s" "$1" | sed -e 's|\\|\\\\|g' -e 's|"|\\"|g')")"
            shift
          done
          vterm_printf "51;E$vterm_elisp"
        }

        if [[ "$INSIDE_EMACS" = 'vterm' ]] \
        && [[ -n ''${EMACS_VTERM_PATH} ]] \
        && [[ -f ''${EMACS_VTERM_PATH}/etc/emacs-vterm-bash.sh ]]; then
    	  source ''${EMACS_VTERM_PATH}/etc/emacs-vterm-bash.sh
        fi        
  '';

  programs.info.enable = true;
}
