{
  config,
  lib,
  options,
  osConfig,
  ...
}:
let
  # inkpotmonkey's commit-signing key. This is a DEDICATED ed25519 key, distinct
  # from identity.sshKey: identity.sshKey doubles as the sops *admin* key
  # (ssh-to-age of it == the &admin recipient), so deploying its private half as a
  # readable signing key onto headless / code-executing hosts (e.g. the kelpy
  # aionui agent) would hand them decryption of every secret in the fleet. The
  # dedicated key's private half is distributed via system sops to every host
  # that is a recipient of users/inkpotmonkey.yaml (see
  # users/inkpotmonkey/nixos/default.nix); its public half (below) is registered
  # on GitHub as a Signing Key. Hosts without the secret fall back to the user's
  # own ~/.ssh key so nothing regresses there.
  signingPub = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINwuFsdbFSteWr3WwV6MCNZfYhtNpsmhKr48ofiRewHY";
  # osConfig is null in a standalone home build (no nixos integration); treat that as
  # "no signing key present" and fall back to ~/.ssh. Slice 13 replaces this
  # osConfig.sops read entirely with hostFacts.granted.signing + the platform resolver.
  sopsSecrets = if osConfig != null then osConfig.sops.secrets or { } else { };
  hasSigningKey = sopsSecrets ? inkpotmonkey_signing_key;
  signingKeyPath =
    if hasSigningKey then
      sopsSecrets.inkpotmonkey_signing_key.path
    else
      "${config.home.homeDirectory}/.ssh/id_ed25519.pub";

  # The git-config tree, assigned to whichever home-manager option exists:
  # unstable exposes the freeform `programs.git.settings`; release-25.11 (the pi
  # hosts) uses `programs.git.extraConfig` for the same structure.
  gitConfig = {
    user = {
      inherit (config.identity) name email;
      signingkey = signingKeyPath;
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
    # Authenticate to GitHub over HTTPS using the system sops github_token
    # (deployed at /run/secrets/github_token, made group-readable in
    # modules/nixos/profiles/nixConfig.nix). Lets headless services like the
    # AionUi backend clone/fetch/push private repos without a token living in
    # any .git/config, and re-reads the file each call so token rotation just
    # works. SSH remotes (git@github.com) bypass this entirely.
    credential."https://github.com".helper =
      ''!f() { test "$1" = get && { echo username=x-access-token; echo "password=$(cat /run/secrets/github_token)"; }; }; f'';
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
      ".ssh/allowed_signers".text =
        if hasSigningKey then
          ''
            * ${signingPub}
          ''
        else
          ''
            * ${config.home.file.".ssh/id_ed25519.pub".text}
          '';
    };
  };
}
