{
  pkgs,
  config,
  lib,
  ...
}:

let
  filteredTreeSitterGrammars = pkgs.lib.filterAttrs (
    n: v: n != "recurseForDerivations" && pkgs.lib.isDerivation v
  ) pkgs.tree-sitter-grammars;

  treesit-grammars-patched =
    (pkgs.emacsPackages.treesit-grammars.override {
      pkgs = pkgs // {
        tree-sitter = pkgs.tree-sitter.overrideAttrs (old: {
          passthru = old.passthru // {
            allGrammars = pkgs.lib.attrValues filteredTreeSitterGrammars;
            builtGrammars = filteredTreeSitterGrammars;
          };
        });
      };
    }).with-all-grammars;
in
{
  options.custom.home.profiles.emacs = {
    enable = lib.mkEnableOption "Emacs configuration (pgtk, tree-sitter, doom-inspired)";
  };

  config = lib.mkIf config.custom.home.profiles.emacs.enable {
    programs.emacs = {
      enable = true;
      package = pkgs.emacs-pgtk;
      extraPackages = epkgs: [
        epkgs.vterm
        epkgs.yaml
        epkgs.just-mode
        epkgs.just-ts-mode
        epkgs.justl
        treesit-grammars-patched
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
              "${../../secrets.yaml}"
              "${treesit-grammars-patched}/lib"
            ]
            (builtins.readFile ./init.el);
      };
      "emacs/early-init.el" = {
        source = ./early-init.el;
      };
    };

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
      unzip
      zip
      cmake

      # :tools editorconfig
      editorconfig-core-c
      # :tools lookup & :lang org +roam
      sqlite
      # :tools images
      imagemagick

      # :lang latex & :lang org (latex previews)
      texlive.combined.scheme-medium

      # formatter
      prettierd

      # LSPs
      nil
      nixfmt
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
  };
}
