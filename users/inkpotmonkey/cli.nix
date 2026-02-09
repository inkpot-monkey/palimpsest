{
  config,
  pkgs,
  ...
}:

let
  hour = 60 * 60;
in
{
  home.packages = with pkgs; [
    nix-search-cli

    unzip

    postgresql
  ];

  home.extraOutputsToInstall = [
    "doc"
    "info"
    "devdoc"
  ];

  home.shellAliases = {
    buildOS = ''sudo nixos-rebuild switch --flake "${config.xdg.configHome}/nixos#stargazer"'';
    bo = "buildOS";
    buildHome = ''home-manager switch --flake "${config.xdg.configHome}/nixos#inkpotmonkey"'';
    bh = "buildHome";
    runUnfree = "NIXPKGS_ALLOW_UNFREE=1 nix run --impure";
    da = "direnv allow";
    nd = "npm run dev";
    nw = "npm run webpack";
    countFiles = "find . -type f | wc -l";
  };

  programs.gpg = {
    enable = true;
  };

  services.gpg-agent = {
    enable = true;
    defaultCacheTtl = 1 * hour;
    maxCacheTtl = 8 * hour;
  };

  services.ssh-agent.enable = true;

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks."*" = {
      addKeysToAgent = "yes";
    };
  };

  home.file.".ssh/config" = {
    target = ".ssh/config_source";
    onChange = "cat ~/.ssh/config_source > ~/.ssh/config && chmod 400 ~/.ssh/config";
  };

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

  home.file = {
    ".ssh/id_ed25519.pub".text = ''
      <SCRUBBED_SSH_KEY>
    '';
    ".ssh/allowed_signers".text = ''
      * ${config.home.file.".ssh/id_ed25519.pub".text}
    '';
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "thomassdk";
        email = "<SCRUBBED_EMAIL>";
        signingkey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      rebase.autostash = true;
      url = {
        "https://" = {
          insteadOf = "git://";
        };
      };
      # Sign all commits using ssh key
      commit.gpgsign = true;
      gpg.format = "ssh";
      gpg.ssh.allowedSignersFile = "${config.home.homeDirectory}/.ssh/allowed_signers";
      core.fsmonitor = true;
    };
    ignores = [
      ".vscode"
      ".lsp"
      ".log"
      ".direnv"
      ".tmp"
      "result*"
      ".dir-locals.el"
      ".env"
      # TODO: Make this a thing in emacs config
      "project.org"
      "gpt.org"
      "*.local.*"
    ];
  };

  programs.password-store = {
    enable = true;
    package = pkgs.pass.withExtensions (exts: [ exts.pass-otp ]);
    settings = {
      PASSWORD_STORE_DIR = "${config.xdg.dataHome}/password-store";
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  programs.nix-index.enable = true;

}
