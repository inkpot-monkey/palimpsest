# rk1b's music library as a git-annex repository (ADR-0027; .scratch/music-pipeline.md §2).
# Imported by rk1b only — rk1a has no library. There is no hosts/rk1b/ directory; rk1b is
# assembled in hosts/default.nix on top of the shared hosts/rk1/common.nix, so host-specific
# files live here alongside it (cf. nvme.nix, inert until enabled).
#
# TOPOLOGY (option "B" in the handoff doc). The repo is owned by the `git-annex` user, not by
# navidrome, and that is not incidental: the module installs the fleet annex SSH key into
# /var/lib/git-annex/.ssh/ (0600, in a 0700 dir owned by git-annex), so a repo whose `user` is
# anyone else can never sync OUTBOUND — it can only receive. Since rk1b holds the authoritative
# library, it must be able to push, therefore git-annex must own the tree.
#
# The inverse (navidrome owning it, git-annex joining the group) was rejected: it makes rk1b
# passive, so new music only reaches kelpy whenever kelpy next polls. The other inverse —
# "fix" the module to hand the key to any repo user — was rejected outright: there is ONE
# keypair for the whole fleet, so that would put a credential granting access to every annex
# repo (including kelpy's `pictures` = personal photos) inside a network-facing web app that
# serves friends. See palimpsest#58 for replacing that shared key with per-node keys.
#
# Navidrome and beets reach the library through the `music` group instead (declared in
# modules/nixos/profiles/navidrome.nix). Navidrome only ever reads it — upstream puts
# MusicFolder in BindReadOnlyPaths — and its supplementary group survives the unit's
# PrivateUsers=true sandbox (verified on the host, not assumed).
{
  config,
  lib,
  settings,
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

      # Watch the library and adopt what beets files, without waiting for a timer.
      assistant = true;

      # rk1b is authoritative and kelpy is a full replica: both want every track.
      group = "backup";
      wanted = "standard";

      # rk1b initiates. kelpy declares the mirror-image remote so either end can reconcile.
      #
      # MagicDNS name, not the bare hostname and not a pinned tailscale IP: rk1b cannot
      # resolve `kelpy` at all (only kelpy carries a networking.hosts pin for rk1b — the
      # asymmetry is easy to miss because the reverse direction works), and
      # settings.nix:130 is explicit that fleet upstreams use `<host>.${settings.tailnet}`
      # because pinned IPs silently rot when a host re-keys.
      remotes = [
        {
          name = "kelpy";
          url = "git-annex@kelpy.${settings.tailnet}:/var/lib/git-annex/music";
        }
      ];
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
