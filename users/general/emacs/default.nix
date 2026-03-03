{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.capabilities.system.programs.emacs;

  myEmacs = pkgs.emacsWithPackagesFromUsePackage {
    config = pkgs.writeText "init.el" ''
      ${builtins.readFile ./init.el}
      ${cfg.extraConfig}

      (provide 'init)
      ;;; init.el ends here
    '';
    defaultInitFile = true;

    package = pkgs.emacs-pgtk;
    alwaysEnsure = true;
    extraEmacsPackages = epkgs: [
      epkgs.treesit-grammars.with-all-grammars
      (epkgs.trivialBuild {
        pname = "link-hint";
        version = "master";
        src = pkgs.fetchFromGitHub {
          owner = "noctuid";
          repo = "link-hint.el";
          rev = "master";
          sha256 = "1v1zrw4fzqsgc3n6aqdsw438svmadwhxi6dg3miagxkpnjirgd8n";
        };
        packageRequires = [ epkgs.avy ];
      })
      (epkgs.trivialBuild {
        pname = "auth-source-sops";
        version = "master";
        src = pkgs.fetchFromGitHub {
          owner = "inkpot-monkey";
          repo = "auth-source-sops";
          rev = "master";
          sha256 = "sha256-XPhiwX0GqneIS7bBxvSxW4LpP1/emYEPmcBG9mT6qUs=";
        };
        packageRequires = [ epkgs.yaml ];
      })
      (epkgs.trivialBuild {
        pname = "goose";
        version = "master";
        src = pkgs.fetchFromGitHub {
          owner = "aq2bq";
          repo = "goose.el";
          rev = "master";
          sha256 = "sha256-LI2ghfilcmF8r0O69FhNDrJpk33gyAWDl05bdsvDHPw=";
        };
        packageRequires = [
          epkgs.vterm
          epkgs.transient
          epkgs.consult
        ];
      })
    ];
  };
in
{
  options.capabilities.system.programs.emacs = {
    # enable option removed - this file IS enablement
    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra Emacs configuration to append to init.el";
    };
  };

  config = {
    # Emacs Service (Daemon)
    services.emacs = {
      enable = true;
      package = myEmacs;
    };

    home.packages = [
      myEmacs
    ];
  };
}
