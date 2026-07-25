# Ongoing health for git-annex repositories — palimpsest#60.
#
# The module fails loudly at INIT (UUID mismatch, unreachable remote → exit 1) and has
# no notion of health after that. Once init succeeds nothing ever checks that
# replication is still happening, and every real bug found during the music bring-up
# exploited exactly that gap: the repo stopped replicating while `git-annex-init-*`
# read `active`, no unit failed, and the logs were quiet. They surfaced only because
# somebody happened to be looking.
#
# ADR-0019 monitors services by default, but it is driven by `settings.services`
# entries with a port or a vhost. A git-annex repo has neither, so annexes are
# invisible to the stack entirely. This closes that: a per-repo node-exporter textfile
# metric, the same idiom the DMARC/TLSRPT/secret-expiry checks use on a
# collection-only stack.
#
# Every series carries a `user` label (the repo's owning user), and each repo also
# emits a constant-1 `git_annex_repo_info` inventory series — together they let one set
# of panels split git-annex usage across both hosts AND users (a home-manager repo on a
# workstation reports through the same schema; see modules/shared/git-annex/metrics.nix,
# which owns the body both callers share).
#
# ## What is a health signal here, and what only looks like one
#
# `remote_reachable` and `assistant_up` are the health signals. Both are independent
# of whether anything has *changed*: the ls-remote probe re-walks the entire outbound
# path (DNS, the annex SSH identity, the peer's git-annex user) on every tick, so it
# reports on an idle library exactly as well as on a busy one. That is what makes a
# heartbeat.
#
# `last_commit_timestamp` is NOT one, and the distinction is load-bearing. #60
# proposed alerting when the last sync aged past a threshold — but a repo's history
# only moves when its CONTENT moves, so a perfectly healthy library that nobody added
# music to for a fortnight would page every time. The timestamp is real context for a
# graph ("when did this repo last do anything?"); it is not a liveness check, and
# nothing alerts on its age. Reachability already covers what that alert was reaching
# for, without the false positives.
#
# ## Why the oneshot runs as root and drops to the repo user per command
#
# It needs both halves of a privilege split that no single User= satisfies:
#   - git must run as `repo.user` — the annex SSH identity lives in git-annex's home
#     (0600 in a 0700 dir), and git's dubious-ownership check rejects another user's
#     repo. `runuser` sets HOME, so ssh finds the identity.
#   - the metrics file must land in the node-exporter textfile dir, which is owned by
#     node-exporter (0775). `repo.user` is not in that group and cannot write there.
# Root brokers both. The alternative — User=repo.user plus SupplementaryGroups —
# breaks on any host without the monitoring-exporters profile, where the group simply
# does not exist and the unit fails to start.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.git-annex;
  mCfg = cfg.metrics;

  # The series and labels are built once, in the shared body builder, so a host repo
  # and a home-manager (user) repo report identically. This module supplies only the
  # host-specific halves: a root→repo-user privilege drop and a system-unit assistant
  # probe (see mkMetricsBody's parameter docs).
  gaMetrics = import ../../../shared/git-annex/metrics.nix { inherit lib pkgs; };

  mkScript =
    name: repo:
    let
      # `runuser` (util-linux), not `sudo`: no PAM stack, no sudoers dependency, and
      # it is what a root-owned unit should use to drop privileges.
      #
      # PATH is passed explicitly through `env` rather than left to the unit's `path`,
      # because runuser RESETS PATH when it switches to a non-root user (su(1): PATH is
      # set from login.defs). Without this git spawns for ls-remote and cannot find
      # `ssh` — which reports every remote as unreachable, i.e. the exporter's own red
      # would be the loudest false alarm on the fleet.
      asRepoUser = lib.concatStringsSep " " [
        "${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg repo.user} --"
        "${pkgs.coreutils}/bin/env"
        # A repo that has lost its identity must fail fast rather than block on a
        # credential prompt for `timeout` to mop up.
        "GIT_TERMINAL_PROMPT=0"
        "PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.git
            pkgs.openssh
          ]
        }"
      ];
    in
    pkgs.writeShellScript "git-annex-metrics-${name}" (
      gaMetrics.mkMetricsBody {
        inherit name repo;
        inherit (mCfg) metricsDir;
        inherit (mCfg) probeTimeout;
        # A NixOS repo is owned by its `user` (default `git-annex`); label the series
        # with it so host and home usage share one schema.
        userLabel = repo.user;
        fileTag = name;
        asRepoPrefix = asRepoUser;
        assistantCheck = "${pkgs.systemd}/bin/systemctl is-active --quiet git-annex-assistant-${name}.service";
      }
    );
in
{
  options.services.git-annex.metrics = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Publish per-repository health metrics (`git_annex_*`) to the node-exporter
        textfile collector directory.

        On by default: an annex that has silently stopped replicating is the module's
        characteristic failure, and an opt-in health check would be off exactly where
        nobody thought to turn it on. Hosts without the monitoring-exporters profile
        have no textfile directory; there the check logs a skip and does nothing.
      '';
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "node-exporter textfile collector directory (see the monitoring-exporters profile, which owns it).";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = ''
        How often to check each repository (a systemd `OnUnitActiveSec` spec). Each tick
        runs one `git ls-remote` per remote, so this trades alert latency against SSH
        chatter; replication is a minutes-scale concern, not a seconds-scale one.
      '';
    };

    probeTimeout = lib.mkOption {
      type = lib.types.str;
      default = "20s";
      description = ''
        Bound on each remote probe (a coreutils `timeout` spec). A hung probe must
        expire well inside `interval`, or checks would pile up on a dead remote —
        which is precisely when the metric matters most.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && mCfg.enable) {
    systemd.services = lib.mapAttrs' (
      name: repo:
      lib.nameValuePair "git-annex-metrics-${name}" {
        description = "Publish health metrics for git-annex repository ${name} (palimpsest#60)";
        # Ordered after init so a first boot reports on a repository that exists,
        # rather than a spurious red while init is still creating it.
        after = [ "git-annex-init-${name}.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = mkScript name repo;
        };
      }
    ) cfg.repositories;

    systemd.timers = lib.mapAttrs' (
      name: _repo:
      lib.nameValuePair "git-annex-metrics-${name}" {
        description = "Periodic health check for git-annex repository ${name}";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = mCfg.interval;
          AccuracySec = "10s";
          Unit = "git-annex-metrics-${name}.service";
        };
      }
    ) cfg.repositories;
  };
}
