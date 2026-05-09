{
  pkgs,
  config,
  lib,
  self,
  ...
}:

{
  options.custom.home.profiles.emacs = {
    enable = lib.mkEnableOption "Emacs configuration (pgtk, tree-sitter, doom-inspired)";
  };

  config = lib.mkIf config.custom.home.profiles.emacs.enable {

    programs.emacs = {
      enable = true;
      package = pkgs.emacsWithPackagesFromUsePackage {
        config = builtins.readFile ./init.el;
        package = pkgs.emacs-pgtk;
        alwaysEnsure = false;
        extraEmacsPackages =
          epkgs:
          [
            epkgs.vterm
            epkgs.yaml
            epkgs.just-mode
            epkgs.just-ts-mode
            epkgs.justl
            epkgs.shell-command-plus
            epkgs.xterm-color
            epkgs.eshell-syntax-highlighting
            # treesit-grammars-patched
            epkgs.treesit-grammars.with-all-grammars
          ]
          ++ (import ./packages.nix {
            inherit epkgs pkgs;
          });
      };
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
              config.identity.username
              config.identity.email
              "${self.lib.getSecretPath "users/inkpotmonkey.yaml"}"
              "${pkgs.emacsPackages.treesit-grammars.with-all-grammars}/lib"
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
      # Emacs specific tools that are not general dev tools
      # (All LSPs and general dev tools are now in dev.nix)
    ];

    programs.bash.bashrcExtra = ''
      # ========================================================================
      # vterm integration (akermu/emacs-libvterm)
      # ========================================================================
      if [[ "$INSIDE_EMACS" = 'vterm' ]]; then
        # Define vterm_printf for proper escape sequence handling
        vterm_printf() {
          if [ -n "$TMUX" ] && ([ "''${TERM%%-*}" = "tmux" ] || [ "''${TERM%%-*}" = "screen" ]); then
            # Tell tmux to pass the escape sequences through
            printf "\ePtmux;\e\e]%s\007\e\\" "$1"
          elif [ "''${TERM%%-*}" = "screen" ]; then
            # GNU screen
            printf "\eP\e]%s\007\e\\" "$1"
          else
            printf "\e]%s\e\\" "$1"
          fi
        }

        # Enable directory tracking and prompt recognition
        vterm_prompt_end() {
          vterm_printf "51;A$(whoami)@$(hostname):$(pwd)"
        }

        # Hook into PROMPT_COMMAND for reliable execution
        PROMPT_COMMAND="''${PROMPT_COMMAND:+''${PROMPT_COMMAND}; }vterm_prompt_end"
      fi
    '';

    programs.info.enable = true;
  };
}
