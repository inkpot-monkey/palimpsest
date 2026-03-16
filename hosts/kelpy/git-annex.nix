{ config, self, ... }:
{
  imports = [ self.nixosModules.git-annex ];

  services.git-annex = {
    enable = true;
    sshKeyFile = config.sops.secrets.git_annex_ssh_key.path;
    gpgKeyFile = config.sops.secrets.git_annex_gpg_key.path;
    repositories = {
      gateway = {
        path = "/var/lib/git-annex/gateway";
        description = "kelpy-gateway";
        uuid = "f6044754-055e-4903-8822-0246a47468d6";
        gateway = true;
        clusterName = "mycluster";
        assistant = true;
        wanted = "not copies=backup:1";
        group = "transfer";
        numcopies = 2;
        remotes = [
          {
            name = "backup";
            url = "/var/lib/git-annex/backup";
            expectedUUID = "1bbbb83d-2136-4a5a-8b32-1d8703fa7639";
            clusterNode = "mycluster";
          }
          {
            name = "rsync_net";
            url = "zh2046@zh2046.rsync.net:annex";
            type = "rsync";
            encryption = "hybrid";
            params = {
              keyid = "376F898EB2D7B0AC";
            };
            group = "backup";
            wanted = "standard";
          }
        ];
      };
      backup = {
        path = "/var/lib/git-annex/backup";
        description = "kelpy-backup";
        group = "backup";
        wanted = "standard";
      };
    };
  };

  environment.persistence."/persistent".directories = [
    "/var/lib/git-annex"
  ];

  programs.git.config.safe.directory = [
    "/var/lib/git-annex/gateway"
    "/var/lib/git-annex/backup"
  ];

  sops.secrets.git_annex_gpg_key = {
    key = "git_annex/gpg_key";
    owner = "git-annex";
    group = "git-annex";
    mode = "0400";
    sopsFile = self.lib.getSecretFile "git-annex";
  };

  sops.secrets.git_annex_ssh_key = {
    key = "git_annex/ssh_key/private";
    owner = "git-annex";
    group = "git-annex";
    mode = "0400";
    sopsFile = self.lib.getSecretFile "git-annex";
  };
}
