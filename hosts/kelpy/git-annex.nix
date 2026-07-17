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

    # A full replica of rk1b's music library (ADR-0027; .scratch/music-pipeline.md §2).
    # rk1b is authoritative and owns the tree there; this is the sharing side — slskd will
    # read it to seed on Soulseek, which is why it is unlocked rather than a tree of symlinks
    # into .git/annex/objects. `thin` makes the working file a hardlink to the annex object
    # (1x disk, not 2x) — kelpy has ~87G on /persistent and that is the whole budget.
    #
    # No `music` group here: nothing else on kelpy touches this tree (Navidrome and beets are
    # rk1b-side), so the repo stays plain git-annex-owned and needs no sharing seam.
    repositories.music = {
      path = "/var/lib/git-annex/music";
      description = "kelpy-music";
      unlock = true;
      thin = true;
      assistant = true;
      group = "backup";
      wanted = "standard";
      remotes = [
        {
          name = "rk1b";
          url = "git-annex@rk1b:/var/cache/music";
        }
      ];
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
