{
  config,
  lib,
  settings,
  self,
  ...
}:
let
  # rsync.net off-site, as a git-annex HYBRID remote (git remote for history +
  # rsync special remote for content — see modules/nixos/services/git-annex/README.md).
  # The module appends `-content` to the special remote internally to avoid the
  # name clash, so one entry gives both halves.
  #
  # This is the first git-annex consumer of rsync.net in the fleet: everything
  # else off-site goes via restic (custom.profiles.backup, currently disabled —
  # palimpsest#150). The account and host key are already established — base.nix
  # pins zh2046.rsync.net's public key, and backup.nix uses the same host for
  # restic — so only the annex side is new here.
  #
  # `encryption = "shared"` means content is encrypted on kelpy before it leaves.
  # The key lives in the git repo, so anyone with repo access can decrypt, but
  # rsync.net only ever holds ciphertext. That is the right trade for a personal
  # photo library on third-party storage.
  #
  # `expectedUUID` is deliberately absent: it is verification-only (nullable in
  # the module), and the UUID does not exist until the remote is initialised
  # once. Fill it in after the first `git annex initremote` so a later
  # re-point at the wrong bucket fails loudly instead of silently resyncing.
  rsyncNet = lib.genAttrs [ "immich-library" "immich-db" ] (repo: {
    name = "rsync_net";
    url = "zh2046@zh2046.rsync.net:${repo}.git";
    type = "rsync";
    encryption = "shared";
  });
in
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

    # A full replica of rk1b's music library (ADR-0028). rk1b is authoritative and owns the
    # tree there; this is the sharing side — slskd will read it to seed on Soulseek, which is
    # why it is unlocked rather than a tree of symlinks into .git/annex/objects. `thin` makes
    # the working file a hardlink to the annex object (1x disk, not 2x) — kelpy has ~87G on
    # /persistent and that is the whole budget, for this AND slskd's downloads.
    #
    # No `music` group here: nothing else on kelpy touches this tree (Navidrome and beets are
    # rk1b-side), so the repo stays plain git-annex-owned and needs no sharing seam.
    #
    # NOTE: this path is persisted into /persistent (below), which restic backs up wholesale
    # — so it is explicitly excluded in hosts/kelpy/configuration.nix. Bulk, re-acquirable
    # data must not go off-site; `pictures` alongside it is personal and must.
    repositories.music = {
      path = "/var/lib/git-annex/music";
      description = "kelpy-music";
      unlock = true;
      thin = true;
      assistant = true;
      group = "backup";
      wanted = "standard";
      # MagicDNS name (`settings.tailnet`), not the bare hostname. A bare `rk1b` happens
      # to resolve here (kelpy carries a networking.hosts pin for it) but that pin is
      # one-directional and host-specific; relying on it is what made the rk1b side fail.
      remotes = [
        {
          name = "rk1b";
          url = "git-annex@rk1b.${settings.tailnet}:/var/cache/music";
        }
      ];
    };

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

    # --- Immich (the Google Photos exit) -------------------------------------
    #
    # Immich is an ACTIVE WRITER into these trees, unlike `pictures` (passive
    # replica) and `music`/`library` (rk1b is authoritative). So both repos are
    # unlocked + thin: the working file is a real file hardlinked to the annex
    # object, which is what lets Immich read and rewrite its own media without
    # tripping over a tree of symlinks.
    #
    # Deliberately NOT one repo at services.immich.mediaLocation. That tree also
    # holds `thumbs/` and `encoded-video/` — derived data Immich regenerates from
    # the originals, and by far the bulkiest part. Annexing it would ship
    # regenerable transcodes to rsync.net at full price. Two scoped repos exclude
    # it by construction rather than by a preferred-content expression that a
    # later edit could widen.
    repositories.immich-library = {
      path = "${config.services.immich.mediaLocation}/library";
      description = "kelpy-immich-library";
      user = config.services.immich.user;
      ownerGroup = config.services.immich.group;
      unlock = true;
      thin = true;
      assistant = true;
      group = "backup";
      wanted = "standard";
      remotes = [ rsyncNet."immich-library" ];
    };

    # The originals are only half a backup. Albums, faces, people, shared links
    # and the whole asset<->file mapping live in postgres, not in library/ — a
    # restore from originals alone gives back the pixels and loses the library.
    # Immich's own scheduled dump lands here, so annexing it captures the DB
    # without pinning services.immich.settings (setting that would make the admin
    # UI read-only for EVERY setting, not just this one).
    #
    # VERIFY AFTER FIRST BOOT: this depends on Immich's scheduled database backup
    # actually being on (Admin -> System Settings -> Backup). If it is off this
    # repo stays empty and the backup is silently originals-only — exactly the
    # "silent non-replication" failure the git-annex metrics section warns about.
    repositories.immich-db = {
      path = "${config.services.immich.mediaLocation}/backups";
      description = "kelpy-immich-db";
      user = config.services.immich.user;
      ownerGroup = config.services.immich.group;
      unlock = true;
      thin = true;
      assistant = true;
      group = "backup";
      wanted = "standard";
      remotes = [ rsyncNet."immich-db" ];
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
