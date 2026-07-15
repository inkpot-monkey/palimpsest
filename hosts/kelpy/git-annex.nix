{
  config,
  lib,
  self,
  ...
}:
{
  imports = [ self.nixosModules.git-annex ];

  # A single plain repository that stores inkpotmonkey's ~/Pictures. The client
  # (users/inkpotmonkey/home/git-annex.nix) is the working copy; this repo wants
  # all content (group backup, wanted standard) so the client's assistant pushes
  # every photo here over SSH. No cluster, proxy, or off-site remote — just a
  # second copy on kelpy.
  services.git-annex = {
    enable = true;
    sshKeyFile = config.sops.secrets.git_annex_ssh_key.path;
    repositories.pictures = {
      path = "/var/lib/git-annex/pictures";
      description = "kelpy-pictures";
      group = "backup";
      wanted = "standard";
    };
  };

  environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
    directories = [
      "/var/lib/git-annex"
    ];
  };

  programs.git.config.safe.directory = [
    "/var/lib/git-annex/pictures"
  ];

  sops.secrets.git_annex_ssh_key = {
    key = "git_annex/ssh_key/private";
    owner = "git-annex";
    group = "git-annex";
    mode = "0400";
    sopsFile = self.lib.getSecretFile "git-annex";
  };
}
