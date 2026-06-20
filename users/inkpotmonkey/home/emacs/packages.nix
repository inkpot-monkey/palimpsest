{ pkgs, epkgs }:
[
  (epkgs.trivialBuild {
    pname = "auth-source-sops";
    version = "unstable-202X";
    src = pkgs.fetchFromGitHub {
      owner = "inkpot-monkey";
      repo = "auth-source-sops";
      rev = "ca3a2d609e8a7bdb2d62c397e1e0cfbcfaa000cf";
      hash = "sha256-XPhiwX0GqneIS7bBxvSxW4LpP1/emYEPmcBG9mT6qUs=";
    };
    packageRequires = [ epkgs.yaml ];
  })
  (epkgs.trivialBuild {
    pname = "ai-code-interface";
    version = "unstable-2026-06-19";
    src = pkgs.fetchFromGitHub {
      owner = "tninja";
      repo = "ai-code-interface.el";
      rev = "453281bd230d7004a517e3b288eff530c3b9d4de";
      hash = "sha256-7nx86SC/KFQ4v85YuwdCSyqnjXUkQp9/eiJnIn/QYGo=";
    };
    packageRequires = [ epkgs.magit ];
  })
  (epkgs.trivialBuild {
    pname = "gptel-quick";
    version = "unstable-202X";
    src = pkgs.fetchFromGitHub {
      owner = "karthink";
      repo = "gptel-quick";
      rev = "018ff2be8f860a1e8fe3966eec418ad635620c38";
      hash = "sha256-7a5+YQifwtVYHP6qQXS1yxA42bVGXmErirra0TrSSQ0=";
    };
    packageRequires = [
      epkgs.gptel
      epkgs.embark
    ];
  })
  (epkgs.trivialBuild {
    pname = "svelte-ts-mode";
    version = "unstable-202X";
    src = pkgs.fetchFromGitHub {
      owner = "leafOfTree";
      repo = "svelte-ts-mode";
      rev = "d079050fc1ba70f8fba9e596638daa2ca96e0fdd";
      hash = "sha256-uYHJP0PyGE27SsztrQCZyuIeHA9Y2x5cfD16BZihg5k=";
    };
  })
  (epkgs.trivialBuild {
    pname = "consult-omni";
    version = "unstable-202X";
    src = pkgs.fetchFromGitHub {
      owner = "armindarvish";
      repo = "consult-omni";
      rev = "bdcd5a065340dce9906ac5c5f359906d31877963";
      hash = "sha256-vmKKEmZpzHQ8RDbTuoTCWGRypLfMiHrEv9Zw0G6K1pg=";
    };
    packageRequires = [
      epkgs.consult
      epkgs.embark
      epkgs.embark-consult
      epkgs.transient
      epkgs.dash
      epkgs.f
    ];
    postInstall = ''
      cp -rv sources $out/share/emacs/site-lisp/
    '';
  })
  (epkgs.trivialBuild {
    pname = "just-complete";
    version = "unstable-202X";
    src = ./just-complete;
  })
]
