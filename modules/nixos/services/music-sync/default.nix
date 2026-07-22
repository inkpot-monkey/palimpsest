# music-sync — drain a local directory to a remote rsync inbox over SSH.
#
# The one job: take whatever files have landed in `source` and move them (rsync
# --remove-source-files) into a remote `target` inbox, then let something on the far
# side consume them. It exists for the acquisition half of the music pipeline — slskd
# downloads on kelpy have to reach rk1b's beets inbox, and the two live on different
# hosts (slskd is on kelpy for the VPN egress, beets/Navidrome/the library are on rk1b).
#
# Why rsync and not git-annex, when the library next door IS git-annex: the download
# queue is transient and one-directional. A file passes through it once — arrives,
# beets retags+moves it into the library, it's gone — so git-annex's durability, dedup
# and multi-copy machinery buy nothing here, while its unlocked-thin working-tree +
# a second annex repo would only add a subtle cross-repo hardlink interaction for
# throwaway data. git-annex guards the thing worth guarding (the library); this does
# the disposable hop. See the music-pipeline notes / ADR-0028 for the split.
#
# Identity: this reuses the fleet git-annex SSH key (default identityFile) rather than
# minting a new sops secret. That key already authenticates as `git-annex@<host>` on
# every module host with a full shell, and using it for rsync grants no access it didn't
# already have (it can reach every annex repo regardless) — so the marginal blast radius
# is zero. The only coupling is that palimpsest#58 (per-node keys) will need to update
# this consumer too.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.music-sync;

  # State dir holds the SSH known_hosts we accept-new into (TOFU). Kept off any
  # impermanence-persisted path on purpose: losing it just re-learns the host key.
  stateDir = "/var/lib/music-sync";

  sync = pkgs.writeShellApplication {
    name = "music-sync";
    runtimeInputs = [
      pkgs.rsync
      pkgs.openssh
      pkgs.findutils
      pkgs.coreutils
    ];
    text = ''
      # Ship every completed file to the remote inbox and delete our copy as each one
      # lands (--remove-source-files), so a tight local disk budget isn't held by data
      # that now lives on the far side. Guarded on there being files, so an empty queue —
      # the backstop timer fires on one constantly — is a cheap no-op, not a spurious sync.
      # The rsync flags, each load-bearing:
      #   * we do NOT preserve owner/group (no -og). Files arrive owned by the SSH identity
      #     (git-annex) and the destination inbox is setgid, so the group is inherited; the
      #     identity can't chown anyway.
      #   * --chmod forces dirs to 2775 (group-writable + setgid) and files to 0664, so the
      #     consumer on the far side (e.g. beets, sharing the inbox's group) can read the
      #     files AND move them out of the album dirs.
      #   * -p (--perms) is REQUIRED for the octal --chmod to be authoritative. Without it
      #     rsync derives dir perms from the source minus umask and the group-write bit is
      #     dropped — the album dir lands 2755 (drwxr-sr-x) and the consumer, though in the
      #     right group, cannot unlink files to drain it.
      #   * --omit-dir-times: with -t, rsync tries to set the mtime of the DESTINATION ROOT
      #     dir (the inbox) to match the source, but the inbox is owned by the consumer, not
      #     the SSH identity, so that fails "Operation not permitted" and rsync exits 23 —
      #     which set -e would treat as a hard failure, aborting before the prune below and
      #     looping the .path watch on the leftover empty dir. Files keep their own mtimes;
      #     only dir mtimes are skipped, and the inbox's perms are owned by tmpfiles anyway.
      if [ -n "$(find "${cfg.source}" -mindepth 1 -type f -print -quit)" ]; then
        rsync -rltp --omit-dir-times --chmod=D2775,F0664 --remove-source-files \
          -e 'ssh -i ${cfg.identityFile} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${stateDir}/known_hosts' \
          "${cfg.source}/" "${cfg.target}/"
      fi

      # ALWAYS prune emptied dirs, even on a run that shipped nothing. --remove-source-files
      # leaves the album dirs behind, and a lingering empty dir keeps the .path unit's
      # DirectoryNotEmpty condition true forever — so if the guard above ever skips straight
      # past one, this unconditional sweep still clears it and the watch settles.
      find "${cfg.source}" -mindepth 1 -type d -empty -delete
    '';
  };
in
{
  options.services.music-sync = {
    enable = lib.mkEnableOption "draining a local directory to a remote rsync inbox over SSH";

    source = lib.mkOption {
      type = lib.types.path;
      description = ''
        Local directory to drain. Every completed FILE under it is rsynced to `target`
        and then removed; emptied directories are pruned. Must contain only files ready
        to ship — keep any in-progress/incomplete staging directory OUTSIDE this path,
        or the .path trigger never settles and half-written files get shipped.
      '';
    };

    target = lib.mkOption {
      type = lib.types.str;
      example = "git-annex@rk1b.example.ts.net:/var/cache/music-inbox";
      description = ''
        rsync destination in `[user@]host:/path` form. The files land owned by this
        SSH identity; the destination directory should be setgid to the group the
        consumer shares, so the consumer can drain what this identity writes.
      '';
    };

    identityFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/git-annex/.ssh/id_ed25519";
      description = ''
        SSH private key used to authenticate to `target`. Defaults to the fleet
        git-annex identity, which every git-annex module host already authorizes — so
        no new secret is needed. The unit's `user` must be able to read this file.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        User the drain runs as. Must be able to read (and delete from) `source` and
        read `identityFile`. Defaults to root because the typical `source` is a
        download directory owned by another service (e.g. slskd's root:media tree),
        which root can drain without group juggling.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/15";
      description = ''
        OnCalendar expression for the backstop timer. The .path unit makes the drain
        responsive; this timer catches anything a missed inotify event stranded, so a
        download never sits forever un-shipped in silence.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Responsive trigger: fire as soon as a completed download appears.
    systemd.paths.music-sync = {
      description = "Watch ${cfg.source} and drain it to the remote inbox";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ cfg.source ];
      pathConfig.DirectoryNotEmpty = cfg.source;
    };

    # Backstop: re-run on a timer so a missed inotify event can't strand a download.
    systemd.timers.music-sync = {
      description = "Backstop drain of ${cfg.source} to the remote inbox";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
      };
    };

    systemd.services.music-sync = {
      description = "Drain ${cfg.source} to ${cfg.target}";
      # A burst of completed files (a whole album finishing near-together) fires the
      # .path trigger many times in quick succession; the default rate limit (5 starts /
      # 10s) trips on that and, worse, marks the .path unit itself failed so it stops
      # watching. Raise it generously — the drain is idempotent and cheap — while still
      # capping a genuine crash-loop, whose real retry is the backstop timer anyway.
      startLimitIntervalSec = 60;
      startLimitBurst = 100;
      # The SSH identity + managed ~/.ssh/config are installed by the git-annex module's
      # ssh-key unit; order after it so the key and accept-new config exist. On a host
      # without that unit (or in a test that boots it separately) the ordering is simply
      # ignored by systemd, so this stays correct everywhere. We order after the plain
      # network.target rather than network-online.target on purpose: a transient network
      # failure just fails this run (visibly, set -euo) and the backstop timer retries, so
      # blocking on network-online buys nothing and would strand the unit on hosts/VMs that
      # never reach that target.
      after = [
        "network.target"
        "git-annex-ssh-key.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        StateDirectory = "music-sync";
        ExecStart = lib.getExe sync;
      };
    };
  };
}
