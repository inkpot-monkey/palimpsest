{
  config,
  lib,
  options,
  ...
}:
let
  # The git-config tree, assigned to whichever home-manager option exists:
  # unstable exposes the freeform `programs.git.settings`; release-25.11 (the pi
  # hosts) uses `programs.git.extraConfig` for the same structure.
  gitConfig = {
    user = {
      inherit (config.identity) name email;
      signingkey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
    };
    init.defaultBranch = "main";
    pull.rebase = true;
    rebase.autostash = true;
    url."https://".insteadOf = "git://";
    # Sign all commits using ssh key
    commit.gpgsign = true;
    gpg.format = "ssh";
    gpg.ssh.allowedSignersFile = "${config.home.homeDirectory}/.ssh/allowed_signers";
    core.fsmonitor = true;
  };
in
{
  options.custom.home.profiles.git = {
    enable = lib.mkEnableOption "git configuration";
  };

  config = lib.mkIf config.custom.home.profiles.git.enable {
    programs.git = lib.mkMerge [
      {
        enable = true;
      }
      (
        if options.programs.git ? settings then { settings = gitConfig; } else { extraConfig = gitConfig; }
      )
      {
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
      }
    ];

    home.file = {
      ".ssh/id_ed25519.pub".text = ''
        ${config.identity.sshKey}
      '';
      ".ssh/allowed_signers".text = ''
        * ${config.home.file.".ssh/id_ed25519.pub".text}
      '';
    };
  };
}
