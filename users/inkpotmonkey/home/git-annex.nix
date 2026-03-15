{
  config,
  lib,
  inputs,
  ...
}:
{
  options.custom.home.profiles.git-annex = {
    enable = lib.mkEnableOption "git-annex assistant for file synchronization";
  };

  imports = [
    inputs.self.homeManagerModules.git-annex
  ];

  config = lib.mkIf config.custom.home.profiles.git-annex.enable {
    sops.secrets.git_annex_gpg_key = {
      key = "git_annex/gpg_key";
      sopsFile = ../../../secrets/git-annex.yaml;
    };

    sops.secrets.git_annex_ssh_key = {
      key = "git_annex/ssh_key/private";
      sopsFile = ../../../secrets/git-annex.yaml;
    };

    services.git-annex = {
      enable = true;
      sshKeyFile = config.sops.secrets.git_annex_ssh_key.path;
      gpgKeyFile = config.sops.secrets.git_annex_gpg_key.path;
      repositories = {
        annex = {
          path = "${config.home.homeDirectory}/annex-test";
          description = "stargazer-annex";
          unlock = true;
          remotes = [
            {
              name = "kelpy";
              url = "git-annex@kelpy:~/gateway";
              proxy = true;
            }
          ];
        };
      };
      assistant.enable = true;
    };
  };
}
