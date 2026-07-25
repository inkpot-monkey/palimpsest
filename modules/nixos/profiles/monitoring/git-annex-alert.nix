# git-annex replication watcher — palimpsest#60. The alerting half of the health
# signal whose measuring half is `services.git-annex.metrics` (see
# modules/nixos/services/git-annex/metrics.nix, which explains what each series means
# and why last_commit is deliberately not one of them).
#
# The split is the point. The service module MEASURES: it knows the repos, owns the
# privilege drop, and publishes `git_annex_*` to the node-exporter textfile dir on
# every git-annex host, whether or not anybody alerts on it. This profile is POLICY:
# it reads those published series and decides what is worth waking someone for. So the
# module stays free of any webhook or Matrix coupling, and adding a repo anywhere on
# the fleet needs no change here — the series appear and are watched.
#
# Reading our own textfiles rather than querying VictoriaMetrics is deliberate: the
# check then runs on the host that owns the repo, needs no network, and keeps working
# when the very link it is reporting on is down. It costs one blind spot — a dead
# exporter leaves a stale file reading `1` forever — which is exactly what
# `git_annex_check_timestamp_seconds` and the staleness check below exist to close. A
# watcher that cannot notice its own source has died is not a watcher.
#
# Quiet semantics mirror the unit-state check: a condition must read bad for
# `failureThreshold` consecutive ticks before it alerts (absorbing deploy/restart
# blips), a recovery notice is sent when it clears, and there are no periodic
# re-alerts while it stays bad.
#
# It watches BOTH kinds of repo: NixOS service repos AND home-manager (user) repos, the
# latter published by the user-run exporter on a workstation. That is what carries the
# alert "across users". A workstation is `on-demand`, and the staleness rule bends for
# it: the user-run writer only publishes while the session is up, so absent/stale
# metrics are expected quiet there, not a dead exporter — only a FRESH bad signal pages
# (the assistant died or the peer went unreachable while the laptop was actually in
# use). An always-on server keeps the strict "stale means the exporter died" rule. The
# presence split is the whole reason a closed laptop lid does not page.
{
  config,
  lib,
  pkgs,
  settings ? null,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-git-annex-alert;

  # What to watch = every git-annex repo on this host that publishes metrics, whether it
  # is a NixOS service repo OR a home-manager (user) repo. The two are discovered
  # separately and merged into a flat list of FILE TAGS (the stem of git-annex-<tag>.prom),
  # because the exporters name their files differently: a system repo publishes
  # git-annex-<repo>.prom, a home repo git-annex-<user>-<repo>.prom (user-namespaced so a
  # workstation repo cannot collide on disk with a same-named system one).
  #
  # Every read is `… or` guarded so this profile is self-contained on a host that imports
  # only one of the two modules — sawtoothShark is home-manager-only and never declares
  # the `services.git-annex` options at all.
  systemGa = config.services.git-annex or null;
  systemRepoTags = lib.optionals (
    systemGa != null && systemGa.enable && (systemGa.metrics.enable or false)
  ) (lib.attrNames systemGa.repositories);

  homeRepoTags = lib.concatLists (
    lib.mapAttrsToList (
      user: userCfg:
      let
        ga = userCfg.services.git-annex or null;
      in
      lib.optionals (ga != null && ga.enable && (ga.metrics.enable or false)) (
        map (name: "${user}-${name}") (lib.attrNames ga.repositories)
      )
    ) (config.home-manager.users or { })
  );

  repoTags = systemRepoTags ++ homeRepoTags;

  # infraAlerts (kelpy's #infra-alerts provisioner) supplies the default webhook, but it
  # is not declared on every host that owns an annex — a workstation running this check
  # has no matrix stack — so guard the reads and require an explicit webhookUrlFile there.
  infraAlerts = config.custom.profiles.matrix.infraAlerts or null;
  infraWebhookDefault = if infraAlerts != null then infraAlerts.webhookUrlFile else null;
  infraEnabled = infraAlerts != null && (infraAlerts.enable or false);

  # This host's operational cadence. on-demand (a workstation) makes absent/stale metrics
  # expected rather than an alarm; always-on (a server) keeps the strict staleness check.
  hostPresence =
    if settings != null then
      (settings.nodes.${config.networking.hostName}.presence or "on-demand")
    else
      "on-demand";

  # The check body is shared with the home-manager alert (a user unit on the workstation)
  # so the two cannot drift — this profile is the always-on-host, root-unit caller.
  gaAlert = import ../../../shared/git-annex/alert.nix { inherit lib pkgs; };
  checkScript = gaAlert.mkCheckScript {
    name = "monitoring-git-annex-alert-check";
    inherit repoTags;
    inherit (cfg)
      webhookUrlFile
      metricsDir
      presence
      failureThreshold
      staleAfterSec
      ;
  };
in
{
  options.custom.profiles.monitoring-git-annex-alert = {
    enable = lib.mkEnableOption ''
      the git-annex replication watcher (palimpsest#60). Reads the per-repo health
      metrics published by `services.git-annex.metrics` on this host and alerts
      #infra-alerts via the hookshot webhook when a repo stops replicating. Enable on
      every host that owns a git-annex repository; pass a webhookUrlFile on hosts that
      do not run custom.profiles.matrix.infraAlerts (which publishes the default)
    '';

    webhookUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = infraWebhookDefault;
      defaultText = lib.literalExpression "config.custom.profiles.matrix.infraAlerts.webhookUrlFile (null if that profile is absent)";
      description = ''
        File holding the #infra-alerts hookshot webhook url the check posts to. Defaults to
        the value infraAlerts publishes; on a host without that profile (e.g. a workstation)
        it must be set explicitly — the assertion below enforces it.
      '';
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      # A literal, not config.services.git-annex.metrics.metricsDir: this check also runs
      # on home-manager-only hosts that never declare the NixOS git-annex options. Both
      # exporters default to this same directory.
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "Directory holding the git-annex-<repo>.prom files this check reads.";
    };

    presence = lib.mkOption {
      type = lib.types.enum [
        "always-on"
        "on-demand"
      ];
      default = hostPresence;
      defaultText = lib.literalExpression "settings.nodes.<hostname>.presence or \"on-demand\"";
      description = ''
        This host's operational cadence. On an `on-demand` host, absent or stale metrics
        are treated as expected quiet (the user-run writer only publishes while the
        session is up) rather than as an "unmonitored" alarm — so a closed laptop lid does
        not page. An `always-on` host keeps the strict staleness check, since there stale
        data means the exporter has genuinely died.
      '';
    };

    intervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        How often (seconds) to re-read the published metrics. Cheap — this only reads
        local files; the SSH probing happens in the exporter, on its own slower timer.
      '';
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        Consecutive bad reads before alerting (debounce that absorbs deploy/restart
        blips — a deploy restarts the assistant). With the default 60s interval, 2 ≈ a
        two-minute grace.
      '';
    };

    staleAfterSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = ''
        Age at which a repo's published metrics count as stale (and the repo as
        unmonitored) rather than as readings. Must comfortably clear
        `services.git-annex.metrics.interval` — the default 15min tolerates two missed
        five-minute checks before crying wolf.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # A host without the (kelpy-only) infraAlerts provisioner — e.g. a workstation —
        # must point the check at a webhook explicitly. `or`-guarded so referencing the
        # matrix profile does not itself error where it is undeclared.
        assertion =
          infraEnabled || (cfg.webhookUrlFile != null && cfg.webhookUrlFile != infraWebhookDefault);
        message = "custom.profiles.monitoring-git-annex-alert requires either custom.profiles.matrix.infraAlerts.enable or an explicit webhookUrlFile.";
      }
      {
        # Something must publish the metrics this check reads. repoTags is empty when no
        # git-annex repo on this host (system OR home-manager) has its exporter enabled.
        assertion = repoTags != [ ];
        message = "custom.profiles.monitoring-git-annex-alert.enable is set but this host has no git-annex repository with metrics enabled (services.git-annex.metrics or the home-manager equivalent) — nothing would be checked.";
      }
      {
        assertion = cfg.staleAfterSec > cfg.intervalSec;
        message = "custom.profiles.monitoring-git-annex-alert: staleAfterSec must exceed intervalSec (and the exporter's interval), or every repo would read as stale.";
      }
    ];

    systemd.services.monitoring-git-annex-alert-check = {
      description = "Alert when a git-annex repository stops replicating (palimpsest#60)";
      after = [ "matrix-infra-alerts-room.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-git-annex-alert";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-git-annex-alert-check = {
      description = "Periodic git-annex replication check (palimpsest#60)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min"; # after the exporter's OnBootSec=2min, so the first read has data
        OnUnitActiveSec = "${toString cfg.intervalSec}s";
        AccuracySec = "10s";
      };
    };
  };
}
