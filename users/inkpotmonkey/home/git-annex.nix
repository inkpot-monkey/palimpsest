{
  config,
  lib,
  inputs,
  ...
}:
{
  imports = [
    inputs.self.homeManagerModules.git-annex
  ];

  config = lib.mkIf (config.identity.profile == "gui") {
    services.git-annex = {
      enable = true;
      sshKey = config.sops.secrets.git_annex_ssh_key.path;
      gpgKey = config.sops.secrets.git_annex_gpg_key.path;
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

    sops.secrets.git_annex_gpg_key = {
      key = "git-annex/gpg_key";
      sopsFile = ../secrets.yaml;
    };

    sops.secrets.git_annex_ssh_key = {
      key = "git-annex/ssh_key/private";
      sopsFile = ../secrets.yaml;
    };
  };
}
