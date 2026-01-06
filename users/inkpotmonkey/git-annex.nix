{
  config,
  self,
  inputs,
  ...
}:
{
  imports = [
    inputs.self.homeManagerModules.git-annex
  ];

  services.git-annex = {
    enable = true;
    sshKey = config.sops.secrets.git_annex_ssh_key.path;
    gpgKey = config.sops.secrets.git_annex_gpg_key.path;
    repositories = {
      annex = {
        path = "/home/inkpotmonkey/annex-test";
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
    sopsFile = "${self}/secrets/secrets.yaml";
  };

  sops.secrets.git_annex_ssh_key = {
    key = "git-annex/ssh_key/private";
    sopsFile = "${self}/secrets/secrets.yaml";
  };
}
