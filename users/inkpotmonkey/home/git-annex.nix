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

  config = lib.mkMerge [
    {
      sops.secrets.git_annex_gpg_key = {
        key = "git-annex/gpg_key";
        sopsFile = ../secrets.yaml;
      };

      sops.secrets.git_annex_ssh_key = {
        key = "git-annex/ssh_key/private";
        sopsFile = ../secrets.yaml;
      };
    }
    (lib.mkIf config.custom.home.profiles.git-annex.enable {
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
    })
  ];
}
