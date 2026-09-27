# rk1b's music library as a git-annex repository. The decision this implements — why
# git-annex owns the tree rather than navidrome, and why the obvious alternative is a
# security hazard — is ADR-0028; read that before changing the ownership model here.
#
# Imported by rk1b only — rk1a has no library. There is no hosts/rk1b/ directory; rk1b is
# assembled in hosts/default.nix on top of the shared hosts/rk1/common.nix, so host-specific
# files live here alongside it (cf. nvme.nix, inert until enabled).
{
  config,
  lib,
  self,
  ...
}:
{
  imports = [ self.nixosModules.git-annex ];

  # rk1b's root is a tmpfs (impermanence), so the git-annex user's HOME — which is where
  # the module installs the annex SSH key and its managed ssh config — would be wiped on
  # every reboot without this. The repo itself lives on the durable NVMe at /var/cache and
  # is unaffected; it is the *identity* that needs persisting, and losing it silently
  # breaks outbound sync rather than failing loudly at boot. Mirrors the same block in
  # hosts/kelpy/git-annex.nix.
  environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
    directories = [
      "/var/lib/git-annex"
    ];
  };

  # The other half of the seam: git-annex owns the tree, navidrome/beets get in via `music`.
  users.users.git-annex.extraGroups = [ "music" ];

  # The repo path is read from Navidrome's MusicFolder below, and the `music` group it
  # shares with is declared by the navidrome profile — so without Navidrome this would
  # silently init an annex against the module-default folder instead of the library.
  # Mirrors the same guard in modules/nixos/profiles/beets.nix.
  assertions = [
    {
      assertion = config.services.navidrome.enable;
      message = "hosts/rk1/git-annex.nix replicates Navidrome's library (services.navidrome.settings.MusicFolder) and shares it via the `music` group declared by custom.profiles.navidrome — enable that profile, or drop this import.";
    }
  ];

  services.git-annex = {
    enable = true;
    sshKeyFile = config.sops.secrets.git_annex_ssh_key.path;

    repositories.music = {
      # Read from Navidrome's own MusicFolder rather than hardcoded, so the library path has a
      # single source of truth (beets.nix does the same).
      path = config.services.navidrome.settings.MusicFolder;
      description = "rk1b-music";

      # `user` is left at the default (git-annex) — see the topology note above.
      ownerGroup = "music";
      # setgid: everything either identity creates in the tree inherits `music`, so beets'
      # output stays reachable by git-annex and git-annex's stays readable by Navidrome.
      # `shared` is deliberately NOT set: the SSH peer and the owner are the same user here,
      # so .git needs no group-write and git's dubious-ownership check never fires.
      mode = "2770";

      # Real files in the worktree, not symlinks into .git/annex/objects. This declares
      # what is already true on disk (checked 2026-09-27: links=1, real files) and is
      # what slskd needs to seed actual bytes now that it runs here rather than off
      # kelpy's replica.
      #
      # `thin` is deliberately NOT set. It would hardlink each working file to its annex
      # object and reclaim ~41G, but beets writes tags into this tree and a write through
      # a thin hardlink mutates the annex object itself. The kelpy replica could afford
      # thin because nothing there ever wrote to it; this tree is written to, so the
      # duplication is the price of safety.
      unlock = true;

      # Watch the library and adopt what beets files, without waiting for a timer.
      assistant = true;

      # rk1b is the only copy now: this repo wants every track.
      group = "backup";
      wanted = "standard";

      # No remotes. The kelpy replica that used to sit on the other end of this link is
      # RETIRED (hosts/kelpy/git-annex.nix) — it existed solely to feed slskd, and slskd
      # now runs here and reads this tree directly. ⚠ That means the library has ONE copy
      # again: replication was the only thing standing in for a backup of it, and
      # custom.profiles.backup is still off fleet-wide (palimpsest#150).
    };
  };

  sops.secrets.git_annex_ssh_key = {
    key = "git_annex/ssh_key/private";
    owner = "git-annex";
    group = "git-annex";
    mode = "0400";
    sopsFile = self.lib.getSecretFile "git-annex";
  };
}
