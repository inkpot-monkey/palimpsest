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
    };
    init.defaultBranch = "main";
    pull.rebase = true;
    rebase.autostash = true;
    url."https://".insteadOf = "git://";
    core.fsmonitor = true;
    # Authenticate to GitHub over HTTPS using the system sops github_token
    # (deployed at /run/secrets/github_token, made group-readable in
    # modules/nixos/profiles/nixConfig.nix). Lets headless agent services (e.g. the
    # Claude relay's `claude` sessions) clone/fetch/push private repos without a
    # token living in any .git/config, and re-reads the file each call so rotation just
    # works. SSH remotes (git@github.com) bypass this entirely.
    credential."https://github.com".helper =
      ''!f() { test "$1" = get && { echo username=x-access-token; echo "password=$(cat /run/secrets/github_token)"; }; }; f'';
    # GitHub username for ghub/Forge. ghub reads this to identify the account and
    # to build its auth-source login (`<user>^forge`); without it Forge fails with
    # "Cannot determine username". The token itself comes from auth-source-sops.
    github.user = "inkpot-monkey";
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
    };
  };
}
