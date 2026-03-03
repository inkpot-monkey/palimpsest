{
  config,
  ...
}:
{
  programs.git = {
    enable = true;
    settings = {
      user = {
        inherit (config.identity) name;
        inherit (config.identity) email;
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

  home.file = {
    ".ssh/id_ed25519.pub".text = ''
      ${config.identity.sshKey}
    '';
    ".ssh/allowed_signers".text = ''
      * ${config.home.file.".ssh/id_ed25519.pub".text}
    '';
  };
}
