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
    pname = "claude-code";
    version = "unstable-202X";
    src = pkgs.fetchFromGitHub {
      owner = "stevemolitor";
      repo = "claude-code.el";
      rev = "4a9914bd4161eb43f489820f9174c62390e5adc8";
      hash = "sha256-ISlD6q1hceckry1Jd19BX1MfobHJxng5ulX2gq9f644=";
    };
    packageRequires = [ epkgs.inheritenv ];
  })
  (epkgs.trivialBuild {
    pname = "gemini-cli";
    version = "unstable-202X";
    src = pkgs.fetchFromGitHub {
      owner = "linchen2chris";
      repo = "gemini-cli.el";
      rev = "7a291a3e65eca50b7352aeb0e808c7984bba5437";
      hash = "sha256-VY0kuRdmcwjB36vVGtv8X3f1Da2qO+e08cqfW2KjOvQ=";
    };
    packageRequires = [
      epkgs.popup
      epkgs.projectile
    ];
  })
  (epkgs.trivialBuild {
    pname = "ai-code-interface";
    version = "unstable-202X";
    src = pkgs.fetchFromGitHub {
      owner = "tninja";
      repo = "ai-code-interface.el";
      rev = "d6ed3eec0209d0bdb7fc9354195e40933b855384";
      hash = "sha256-uGMEdH6GeIUwXqPVpps4jk2OwhwToeJJPk3Yw5s3nx0=";
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
]
