# User-level git-annex replication alert (palimpsest#60), the workstation counterpart of
# the NixOS profile (modules/nixos/profiles/monitoring/git-annex-alert.nix). Same check
# body, same #infra-alerts webhook, same quiet/debounce/presence semantics — but it runs
# as the USER, so:
#   - the webhook secret is decrypted by the user's own sops (the admin key already on the
#     box), needing no host re-key and keeping the secret in the user's domain;
#   - it only ticks while the session is up, which is exactly when this on-demand host's
#     metrics are fresh — so a closed laptop lid simply stops checking, and `presence` is
#     pinned to on-demand as belt-and-suspenders (stale/absent → quiet, never a page).
#
# It watches this user's own repos (the metrics writer publishes git-annex-<user>-<repo>.prom),
# so it needs services.git-annex.metrics enabled alongside it — the source it reads.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.git-annex;
  aCfg = cfg.alert;
  gaAlert = import ../../shared/git-annex/alert.nix { inherit lib pkgs; };

  # The user's repos, tagged the way the user-run writer names its files.
  repoTags = map (name: "${config.home.username}-${name}") (lib.attrNames cfg.repositories);

  checkScript = gaAlert.mkCheckScript {
    name = "git-annex-alert-check";
    inherit repoTags;
    inherit (aCfg)
      webhookUrlFile
      metricsDir
      failureThreshold
      staleAfterSec
      ;
    # A workstation user unit: session-scoped already, and defensively quiet on stale/absent.
    presence = "on-demand";
  };

  serviceUnit = pkgs.writeText "git-annex-alert-check.service" ''
    [Unit]
    Description=Alert when a git-annex repository stops replicating (palimpsest#60)

    [Service]
    Type=oneshot
    StateDirectory=git-annex-alert
    ExecStart=${checkScript}
  '';

  # A user timer: OnActiveSec is relative to the timer starting with the user manager
  # (there is no "boot" for a --user instance), then every interval.
  timerUnit = pkgs.writeText "git-annex-alert-check.timer" ''
    [Unit]
    Description=Periodic git-annex replication check (palimpsest#60)

    [Timer]
    OnActiveSec=90s
    OnUnitActiveSec=${toString aCfg.intervalSec}s
    AccuracySec=10s

    [Install]
    WantedBy=timers.target
  '';
in
{
  options.services.git-annex.alert = {
    enable = lib.mkEnableOption ''
      a user-level git-annex replication watcher that reads this user's health metrics
      (services.git-annex.metrics) and alerts #infra-alerts via the hookshot webhook when
      a repo stops replicating. Runs as the user so the webhook secret stays in the user's
      sops domain; requires services.git-annex.metrics.enable (the source it reads) and a
      webhookUrlFile
    '';

    webhookUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File whose contents are the #infra-alerts hookshot webhook url. Assemble it from
        the user's own sops (e.g. a sops.template over infra_alerts_hook_id) — the admin
        key already decrypts matrix.yaml, so no host re-key is needed.
      '';
    };

    metricsDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "Directory holding the git-annex-<user>-<repo>.prom files this check reads.";
    };

    intervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "How often (seconds) to re-read the published metrics.";
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Consecutive bad reads before alerting (debounce that absorbs restart blips).";
    };

    staleAfterSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = ''
        Age at which published metrics count as stale. On this on-demand user unit stale
        data is treated as expected quiet, never a page — but it must still exceed
        intervalSec so a live check never reads itself as stale.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && aCfg.enable) {
    assertions = [
      {
        assertion = cfg.metrics.enable;
        message = "services.git-annex.alert reads the metrics published by services.git-annex.metrics — enable metrics too, or drop the alert.";
      }
      {
        assertion = aCfg.webhookUrlFile != null;
        message = "services.git-annex.alert.enable is set but no webhookUrlFile — the check would have nowhere to post.";
      }
      {
        assertion = aCfg.staleAfterSec > aCfg.intervalSec;
        message = "services.git-annex.alert: staleAfterSec must exceed intervalSec, or a live check would read itself as stale.";
      }
    ];

    xdg.configFile = {
      "systemd/user/git-annex-alert-check.service".source = serviceUnit;
      "systemd/user/git-annex-alert-check.timer".source = timerUnit;
      "systemd/user/timers.target.wants/git-annex-alert-check.timer".source = timerUnit;
    };
  };
}
