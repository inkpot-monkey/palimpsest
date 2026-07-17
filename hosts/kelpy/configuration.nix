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
    # Temporarily disabled: the restic repo (zh2046.rsync.net) is unreachable and
    # holds a stale exclusive lock from stargazer, failing every activation.
    # Re-enable once the lock is cleared and the host is reachable.
    backup.enable = false;
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
      hookshot.enable = true;
      infraAlerts = {
        enable = true;
        # Pinned from the matrix-infra-alerts-room oneshot's first run (a static
        # hookshot connection needs the server-assigned roomId at build time).
        roomId = "!oHttFPAVTE9qwcYCjp:matrix.palebluebytes.space";
      };
    };
    paperless.enable = true;
    litellm.enable = true;
    # The Claude relay (ADR-0018) is the Matrix interface to persistent `claude`
    # sessions — it replaced AionUi (now removed). Reuses inkpotmonkey's ~/.claude.
    claude-relay.enable = true;
    blocky.enable = true;
    media = {
      enable = true;
    };
  };

  # kelpy runs the Claude relay's code-executing `claude` sessions (claude-relay
  # above) — mark it exposed so the contract refuses any secret-bearing user-feature
  # grant (contract ADR-0001).
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
    # `backup.enable` flips true (see the note above — it is off only because the
    # rsync.net repo is unreachable, and is meant to come back) the entire library
    # would ship to rsync.net. `thin` makes the worktree files hardlinks to the annex
    # objects, which restic reads as full content, so it would go twice over.
    #
    # Scoped to `music` deliberately: the `pictures` repo alongside it is personal
    # photos and SHOULD be backed up. Do not widen this to /var/lib/git-annex.
    exclude = [ "/persistent/var/lib/git-annex/music" ];
  };

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
