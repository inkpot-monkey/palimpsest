{ ... }:
{
  services.git-annex = {
    enable = true;
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
            encryption = "none";
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
}
