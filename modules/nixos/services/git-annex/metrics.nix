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

  # Escape a string for use as a Prometheus label VALUE. Repo and remote names are
  # Nix attribute names and free-text-ish; a stray quote would corrupt the exposition
  # format for every series in the file.
  promLabel = lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" " " ];

  # A remote has a git URL to probe whenever `url` is set — including hybrid remotes,
  # which are a git remote AND a special remote under one entry (cf. shared/lib.nix).
  gitRemotes = repo: lib.filter (r: r.url != null) repo.remotes;

  mkScript =
    name: repo:
    let
      repoLabel = promLabel name;
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
    pkgs.writeShellScript "git-annex-metrics-${name}" ''
      set -u

      metrics_dir=${lib.escapeShellArg mCfg.metricsDir}
      if [ ! -d "$metrics_dir" ]; then
        # Best-effort, mirroring secret-expiry: the monitoring-exporters profile owns
        # this directory, and a git-annex host without it simply has nowhere to publish.
        # Never fail the oneshot over it.
        echo "git-annex-metrics: metrics dir $metrics_dir absent — skipping ${name}" >&2
        exit 0
      fi

      tmp="$(${pkgs.coreutils}/bin/mktemp "$metrics_dir/.git-annex-${name}.XXXXXX")"
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT

      emit() { printf '%s\n' "$1" >> "$tmp"; }

      # `timeout` lives INSIDE the privilege drop, not outside it: timeout execs a
      # binary, so it cannot run a shell wrapper around runuser at all.
      as_repo() { ${asRepoUser} "$@"; }
      as_repo_bounded() { as_repo ${pkgs.coreutils}/bin/timeout ${mCfg.probeTimeout} "$@"; }

      ${lib.optionalString repo.assistant ''
        emit '# HELP git_annex_assistant_up Whether the git-annex assistant for this repository is running (1) or not (0).'
        emit '# TYPE git_annex_assistant_up gauge'
        if ${pkgs.systemd}/bin/systemctl is-active --quiet git-annex-assistant-${name}.service; then
          emit 'git_annex_assistant_up{repo="${repoLabel}"} 1'
        else
          emit 'git_annex_assistant_up{repo="${repoLabel}"} 0'
        fi
      ''}

      ${lib.optionalString (gitRemotes repo != [ ]) ''
        emit '# HELP git_annex_remote_reachable Whether the repository could reach this git remote (1) or not (0).'
        emit '# TYPE git_annex_remote_reachable gauge'
      ''}
      ${lib.concatMapStringsSep "\n" (remote: ''
        # ls-remote, not fetch: it is read-only, cheap, and touches nothing in the repo,
        # yet it still exercises the full outbound path a sync depends on.
        if as_repo_bounded ${pkgs.git}/bin/git -c credential.helper= \
             -C ${lib.escapeShellArg repo.path} \
             ls-remote --quiet ${lib.escapeShellArg remote.name} HEAD >/dev/null 2>&1; then
          emit 'git_annex_remote_reachable{repo="${repoLabel}",remote="${promLabel remote.name}"} 1'
        else
          emit 'git_annex_remote_reachable{repo="${repoLabel}",remote="${promLabel remote.name}"} 0'
        fi
      '') (gitRemotes repo)}

      # Newest commit on ANY ref, so it tracks the annex branches the assistant writes
      # (synced/*, git-annex) and not just whatever HEAD happens to be — on an unlocked
      # repo HEAD is an adjusted branch that need not move on a sync at all.
      last_commit="$(as_repo ${pkgs.git}/bin/git -C ${lib.escapeShellArg repo.path} \
        for-each-ref --sort=-committerdate --count=1 --format='%(committerdate:unix)' 2>/dev/null || true)"
      if [ -n "$last_commit" ]; then
        emit '# HELP git_annex_last_commit_timestamp_seconds Unix time of the newest commit on any ref. Context, NOT liveness — a healthy idle repo goes stale by design (see the module header).'
        emit '# TYPE git_annex_last_commit_timestamp_seconds gauge'
        emit "git_annex_last_commit_timestamp_seconds{repo=\"${repoLabel}\"} $last_commit"
      fi

      # The exporter's own heartbeat: without it a dead check is indistinguishable from
      # a healthy repo, because the last-published file just sits there reading 1.
      emit '# HELP git_annex_check_timestamp_seconds Unix time this repository health check last completed.'
      emit '# TYPE git_annex_check_timestamp_seconds gauge'
      emit "git_annex_check_timestamp_seconds{repo=\"${repoLabel}\"} $(${pkgs.coreutils}/bin/date +%s)"

      # mktemp makes the file 0600; node-exporter runs as its own user and must READ it.
      # Skip this and the metric is published but never scraped — the panel shows "No
      # data" and nothing anywhere says why.
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/git-annex-${name}.prom"
    '';
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
