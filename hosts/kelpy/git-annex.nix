{
  config,
  lib,
  settings,
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

    # PINNED to what this host already has, so adopting the pin needs no chown. Not
    # cosmetic: the 2026-10-18 reboot moved the map out from under the persisted tree
    # (`drwx------ 983:979` against a live 995:995), the init units failed, and the
    # library assistant then crash-looped 5,593 times in 15 hours into a capped journal.
    # Changing either number later means `chown -R` over /var/lib/git-annex — a redeploy
    # will not do it. 995 is free on this host only; rk1b pins its own pair.
    uid = 995;
    gid = 995;
    repositories.pictures = {
      path = "/var/lib/git-annex/pictures";
      description = "kelpy-pictures";
      group = "backup";
      wanted = "standard";
    };

    # The `music` replica is RETIRED. It existed for exactly one consumer — slskd, which
    # read it to seed on Soulseek (ADR-0028) — and slskd moved to rk1b, where the
    # authoritative library already lives at /var/cache/music. Keeping a full second copy
    # on this host's 90G disk to feed a service that is no longer here would be pure cost,
    # so the repo, its assistant and its rk1b remote all go. rk1b remains authoritative;
    # nothing else on kelpy ever touched this tree.

    # A full replica of rk1b's Supernote document library (ADR-0031, palimpsest#90). Like the
    # music replica it is unlocked + thin (real files hardlinked to the annex object, 1x disk),
    # but UNLIKE music this tree IS backed up offsite: it is personal documents, not
    # re-acquirable media — so it is deliberately NOT added to the restic `exclude` in
    # hosts/kelpy/configuration.nix (the music-only exclusion must not be widened to cover it).
    #
    # Plain git-annex-owned (no `library` group here — nothing on kelpy reads the tree; the
    # reconciler and Stump are rk1b-side), so it needs no sharing seam and no safe.directory.
    repositories.library = {
      path = "/var/lib/git-annex/library";
      description = "kelpy-library";
      unlock = true;
      thin = true;
      assistant = true;
      group = "backup";
      wanted = "standard";
      # MagicDNS name (settings.tailnet), the mirror image of the rk1b remote in
      # hosts/rk1/library.nix — not a bare hostname or a pinned IP.
      remotes = [
        {
          name = "rk1b";
          url = "git-annex@rk1b.${settings.tailnet}:/var/cache/library";
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
