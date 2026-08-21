{
  config,
  inputs,
  lib,
  pkgs,
  self,
  settings,
  ...
}:
{
  imports = [
    inputs.vpsFree.nixosModules.containerUnstable

    self.nixosProfiles.bundle

    ./git-annex.nix
  ];

  custom.profiles = {
    base.enable = true;
    impermanence.enable = true;
    tailscale = {
      enable = true;
      tags = [ "tag:server" ];
    };
    ssh.enable = true;
    # Deliberately NOT passwordless sudo: kelpy is the public-facing VPS, so keep
    # the sudo password as defense-in-depth. `just deploy kelpy` supplies it via
    # --ask-sudo-password (prompted once, up front).
    proxy.enable = true;
    # DEFERRED, not blocked — the reason this is off is a scheduling decision, not an
    # obstacle. The older note here said rsync.net was unreachable and held a stale
    # exclusive lock from stargazer; both halves have decayed:
    #   • zh2046.rsync.net is REACHABLE — TCP 22 connects from this host (checked
    #     2026-08-19). "Unreachable" has not been true for some time.
    #   • stargazer no longer configures backup at all, so nothing there can still be
    #     taking a lock. Whether the repo carries a leftover one is untested, and is only
    #     testable by running restic.
    # Turning this on is what ships the document library replica offsite (see the paths /
    # exclude / assertion below — the wiring is already correct and needs no path change).
    # Tracked in palimpsest#150, which carries the fleet-wide picture and the open
    # questions. Until then the library lives on two git-annex replicas and nowhere else.
    backup.enable = false;
    # Still surface this host's off-site job on the Backups board — as a known-off edge.
    backup.reportJobs = [ "daily" ];
    monitoring-server.enable = false; # moved to rk1b (ADR-0021)
    monitoring-client.enable = true;
    monitoring-dmarc.enable = false;
    # On-host white-box layer for ADR-0019: alerts to #infra-alerts (via the
    # hookshot loopback webhook) when a long-running daemon stops being active —
    # complements the off-host Gatus reachability probe on rk1b. The unit list is
    # CURATED (these names are kelpy-specific); add/remove as services change.
    # affine is intentionally omitted (it currently has no unit on kelpy).
    monitoring-unit-state = {
      enable = true;
      units = [
        "caddy.service" # the edge — everything web-facing depends on it
        "blocky.service" # fleet DNS
        "stalwart.service" # mail
        "tuwunel.service" # matrix homeserver
        "matrix-hookshot.service" # the alert delivery path itself
        "litellm.service"
        "jellyfin.service"
        "podman-qbittorrent-app.service" # torrent
        "podman-slskd.service" # Soulseek music seeder (ADR-0029)
        # music-sync.service is deliberately NOT listed: it is a oneshot (path/timer
        # triggered), so it is `inactive` by design between runs and this active-watch
        # would spam. A failed drain surfaces via its systemd unit-state metric + the
        # backstop timer's retry; a dedicated OnFailure alert is a possible follow-up.
        "vector.service" # monitoring-client still runs here; server moved to rk1b
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-consumer.service"
      ];
    };
    # Daily secret-expiry watcher (ADR-0024): reads the plaintext expiry registry
    # (secrets/expiry.nix) and alerts #infra-alerts before a rotatable secret (e.g.
    # the 90-day tailscale auth key) lapses. Reuses the infraAlerts webhook + the
    # node-exporter textfile metric for a Grafana "days remaining" gauge.
    monitoring-secret-expiry.enable = true;
    # git-annex replication watcher (palimpsest#60): a git-annex repo that stops
    # replicating reports healthy in every other way, so nothing else here can see it.
    # Uses the infraAlerts webhook by default, like the checks above.
    #
    # This covers the `music` replica (assistant + remote → rk1b). It does NOT
    # meaningfully cover `pictures`: that repo is passive — no assistant, no remotes,
    # the desktop's home-manager client pushes INTO it — so the only signal available
    # on this side is whether the check itself still runs. Watching the photo link
    # properly means teaching the home-manager module to export too, which is where
    # that repo's outbound half actually lives. Not done here.
    monitoring-git-annex-alert.enable = true;
    mail = {
      enable = true;
      inherit (settings.mail) domain extraDomains;
    };
    # Auto-reconcile the mail domains' DANE/TLSA records when acme renews the mail cert,
    # so the published TLSA never drifts from the served cert (mail-scoped dns push).
    mail-dane-autoupdate.enable = true;
    matrix = {
      enable = true;
      whatsapp.enable = true;
      jmap-bridge.enable = true;
      hookshot = {
        enable = true;
        # Keep the personal GitHub notification feed out of the @hookshot admin DM
        # and in its own room, so the DM stays a command surface. `github login`
        # (per-user OAuth) is still run by hand, once, in the DM.
        notificationsRoom.enable = true;
        # `github login` cannot drive the notification feed: GET /notifications
        # rejects GitHub App tokens outright and only takes a classic PAT. Store one
        # from sops rather than pasting it into the (unencrypted) admin DM. Reuses
        # the fleet `github_token` declared by nixConfig.nix — classic, `repo` scope,
        # which is what makes private-repo notifications render.
        personalToken = {
          enable = true;
          secretName = "github_token";
        };
      };
      # The room id is no longer a build-time input: the connection is provisioned
      # into room state at runtime, so the oneshot creates the room and persists
      # its id. The previously pinned id was wiped by a July matrix-reset and had
      # been dead for weeks, which is precisely the failure mode that removed it.
      infraAlerts.enable = true;
    };
    paperless.enable = true;
    litellm.enable = true;
    blocky.enable = true;
    media = {
      enable = true;
      # slskd seeds the git-annex `music` replica (ADR-0028) out to Soulseek, through
      # the same ProtonVPN container the torrent stack uses. Reads the replica in
      # ./git-annex.nix read-only; web UI fronted tailnet-only at slskd.<domain>.
      slskd.enable = true;
    };
  };

  # kelpy is internet-facing (public Caddy edge, a federated homeserver) and runs
  # services that reach out on the operator's behalf — mark it exposed so the contract
  # refuses any secret-bearing user-feature grant (contract ADR-0001). Set originally
  # for the Claude relay's code-executing `claude` sessions (ADR-0018, since removed);
  # kept because the posture is the host's, not that one service's.
  custom.host.exposed = true;
  # NOTE: signing is intentionally NOT granted here. It is now a home-sops feature
  # (contract ADR-0002, slice 13) decryptable only by the user's own key, which a headless
  # agent host lacks — and the agent should not sign commits as inkpotmonkey anyway.

  networking = {
    inherit (settings.nodes.kelpy) hostName domain;
  };

  # Gate the WHOLE `daily` entry on the backup profile: writing `.daily.paths`
  # alone would still instantiate `restic.backups.daily` (empty → fails the
  # repository/passwordFile assertions) when the profile, which supplies those,
  # is disabled. mkIf on the attrset removes the entry entirely.
  services.restic.backups.daily = lib.mkIf config.custom.profiles.backup.enable {
    paths = [ "/persistent" ];
    # The music replica must never go off-site: it is bulk, re-acquirable data, not
    # personal documents — and once seeded it is by far the largest thing on this 90G
    # host. This is not hypothetical housekeeping: `paths` is /persistent wholesale,
    # and hosts/kelpy/git-annex.nix persists /var/lib/git-annex into it, so the day
    # `backup.enable` flips true (see the note above — it is off by deferral, and is meant
    # to come back) the entire library would ship to rsync.net. `thin` makes the worktree
    # files hardlinks to the annex
    # objects, which restic reads as full content, so it would go twice over.
    #
    # Scoped to `music` deliberately: the `pictures` repo alongside it is personal
    # photos and SHOULD be backed up. Do not widen this to /var/lib/git-annex — the
    # Supernote document library replica (`/var/lib/git-annex/library`, ADR-0031 /
    # palimpsest#90) lives there too and is DELIBERATELY included offsite (personal
    # documents, not re-acquirable media), so it must stay out of this exclude list.
    # NOTE: `backup.enable` is currently false above (deferred — palimpsest#150), so nothing
    # ships until it returns; when it does, `library` goes offsite via the /persistent path.
    #
    # slskd's own downloads (ADR-0029) are the same category — bulk, re-acquirable data
    # that must never ship off-site — so they are excluded too. slskd's small state dir
    # (/var/lib/slskd: share DB, config) is left in: it is not bulk and is cheap to keep.
    exclude = [
      "/persistent/var/lib/git-annex/music"
      "/persistent/var/lib/media/slskd-downloads"
    ];
  };

  # Enforce the ADR-0031/#90 divergence from music: the document library replica MUST go
  # offsite, so no restic exclude may cover it. The comments above can't stop a future edit
  # widening the music exclusion to /var/lib/git-annex; this fails the build the moment such an
  # exclude covers the library — as soon as backup is re-enabled. Lazy-safe: when backup is off,
  # restic.backups.daily (and its `exclude`) is removed by the mkIf, but `||` short-circuits
  # before the second operand ever forces it.
  assertions = [
    {
      assertion =
        !config.custom.profiles.backup.enable
        || !lib.any (
          e: lib.hasPrefix e "/persistent/var/lib/git-annex/library"
        ) config.services.restic.backups.daily.exclude;
      message = "hosts/kelpy: a restic exclude now covers the Supernote document library replica (/persistent/var/lib/git-annex/library), but ADR-0031/#90 requires it backed up offsite. Do not widen the music exclusion to /var/lib/git-annex.";
    }
  ];

  # Persist the agent's home state across impermanence reboots: Claude Code
  # subscription credentials/config and the project checkouts the relay's sessions
  # work in.
  environment.persistence."/persistent".users.inkpotmonkey.directories = [
    ".claude"
    "code"
  ];

  nixpkgs = {
    hostPlatform = "x86_64-linux";
  };

  environment.systemPackages = with pkgs; [
    git
  ];

  system.stateVersion = "25.11";
}
