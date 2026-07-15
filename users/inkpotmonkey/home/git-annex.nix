{
  config,
  lib,
  inputs,
  self,
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
    sops.secrets.git_annex_ssh_key = {
      key = "git_annex/ssh_key/private";
      sopsFile = self.lib.getSecretFile "git-annex";
    };

    services.git-annex = {
      enable = true;
      sshKeyFile = config.sops.secrets.git_annex_ssh_key.path;
      repositories = {
        # ~/Pictures is the working copy. unlock = true keeps photos as real,
        # editable files (image viewers see files, not annex symlinks). The
        # assistant auto-syncs to kelpy's `pictures` repo over SSH, which wants
        # all content — so every photo gets a second copy on kelpy. A plain
        # client <-> server pair: no cluster, proxy, or encryption.
        pictures = {
          path = "${config.home.homeDirectory}/Pictures";
          description = "inkpotmonkey-pictures";
          unlock = true;
          remotes = [
            {
              name = "kelpy";
              url = "git-annex@kelpy:~/pictures";
            }
          ];
        };
      };
      assistant.enable = true;
    };
  };
}
