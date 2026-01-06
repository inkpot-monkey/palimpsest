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
      epkgs.yaml
      epkgs.treesit-grammars.with-all-grammars
    ];
  };

  services.emacs = {
    enable = true;
    package = config.programs.emacs.finalPackage;
    startWithUserSession = false; # Don't start at login
    socketActivation.enable = true; # Wait for client connection
  };

  # Emacs configuration
  xdg.configFile = {
    "emacs/init.el" = {
      text =
        builtins.replaceStrings
          [
            "@username@"
            "@email@"
            "@secrets@"
            "@treesit-grammars@"
          ]
          [
            "inkpot-monkey"
            "inkpot-monkey@palebluebytes.space"
            "${../secrets.yaml}"
            "${pkgs.emacsPackages.treesit-grammars.with-all-grammars}/lib"
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
    # Only run this logic if we are actually inside vterm
    if [[ "$INSIDE_EMACS" = 'vterm' ]]; then
      # Source the official vterm setup script directly from the Nix store
      # This replaces the manual vterm_printf, vterm_cmd, etc.
      source "${pkgs.emacsPackages.vterm}/share/emacs/site-lisp/elpa/vterm-*/etc/emacs-vterm-bash.sh"

      # Optional: Prompt tracking (if the sourced script doesn't auto-detect your specific prompt setup)
      # vterm needs to know where the prompt ends to allow moving the cursor by "prompts" in Emacs
      vterm_prompt_end() {
          vterm_printf "51;A$(whoami)@$(hostname):$(pwd)"
      }
      PS1=$PS1'\[$(vterm_prompt_end)\]'
    fi
  '';

  programs.info.enable = true;
}
