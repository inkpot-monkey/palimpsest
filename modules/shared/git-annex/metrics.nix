# The shell body that publishes one git-annex repository's health metrics, shared by
# the NixOS service module (modules/nixos/services/git-annex/metrics.nix, root-brokered)
# and the home-manager module (modules/homeManager/git-annex, user-run). Both emit the
# SAME series to the node-exporter textfile collector; factoring the body out is what
# keeps a host repo and a user repo reporting identically — the same reason lib.nix
# exists for the init path (cf. a630b47).
#
# What differs between the two callers is only the privilege wrapper and how the
# assistant's liveness is queried, so those are parameters (`asRepoPrefix`,
# `assistantCheck`); everything about WHICH series are emitted and how they are labelled
# lives here, once.
#
# Unlike lib.nix this needs `pkgs` (it bakes coreutils/git/openssh store paths into the
# script), so it is a separate import rather than folded into the pure lib.
{ lib, pkgs }:
let
  # Escape a string for use as a Prometheus label VALUE. Repo/remote/user names and
  # free-text descriptions are attribute names or user input; a stray quote would
  # corrupt the exposition format for every series in the file.
  promLabel = lib.replaceStrings [ "\\" "\"" "\n" ] [ "\\\\" "\\\"" " " ];

  # A remote has a git URL to probe whenever `url` is set — including hybrid remotes,
  # which are a git remote AND a special remote under one entry (cf. lib.nix).
  gitRemotes = repo: lib.filter (r: r.url != null) repo.remotes;

  # A submodule option that is present-but-null (group/wanted default to null) must
  # become an empty label value, not the string "null".
  orEmpty = v: if v == null then "" else toString v;
in
{
  inherit promLabel gitRemotes;

  # Build the shell body (everything after the shebang) that writes `git-annex-<fileTag>.prom`.
  #
  #   name           repository attribute name (the `repo` label + default file tag)
  #   repo           the per-repository submodule config (path, remotes, description, …)
  #   metricsDir     node-exporter textfile collector directory
  #   probeTimeout   coreutils `timeout` spec bounding each ls-remote probe
  #   userLabel      value of the `user` label — the repo's owning user (host repos are
  #                  `git-annex`; a home repo is the human who owns it), so a single set
  #                  of panels can split annex usage across hosts AND users
  #   fileTag        stem of the published file: git-annex-<fileTag>.prom (host repos use
  #                  `name`; a home repo prefixes the user to avoid colliding on disk with
  #                  a same-named system repo)
  #   asRepoPrefix   shell prefix that runs a command as the repo user (the root caller
  #                  passes a `runuser … env …` string; the user-run caller passes an
  #                  `env GIT_TERMINAL_PROMPT=0` with no privilege drop)
  #   assistantCheck shell command exiting 0 iff the assistant is up (only consulted when
  #                  repo.assistant); the root caller queries the system unit, the user
  #                  caller queries `systemctl --user`
  mkMetricsBody =
    {
      name,
      repo,
      metricsDir,
      probeTimeout,
      userLabel,
      fileTag,
      asRepoPrefix,
      assistantCheck,
    }:
    let
      repoLabel = promLabel name;
      userLbl = promLabel userLabel;
    in
    ''
      set -u

      metrics_dir=${lib.escapeShellArg metricsDir}
      if [ ! -d "$metrics_dir" ]; then
        # Best-effort, mirroring secret-expiry: the monitoring-exporters profile owns
        # this directory, and a git-annex host without it simply has nowhere to publish.
        # Never fail over it.
        echo "git-annex-metrics: metrics dir $metrics_dir absent — skipping ${name}" >&2
        exit 0
      fi

      tmp="$(${pkgs.coreutils}/bin/mktemp "$metrics_dir/.git-annex-${fileTag}.XXXXXX")"
      trap '${pkgs.coreutils}/bin/rm -f "$tmp"' EXIT

      emit() { printf '%s\n' "$1" >> "$tmp"; }

      # `timeout` lives INSIDE the privilege drop, not outside it: timeout execs a
      # binary, so it cannot run a shell wrapper around the prefix at all.
      as_repo() { ${asRepoPrefix} "$@"; }
      as_repo_bounded() { as_repo ${pkgs.coreutils}/bin/timeout ${probeTimeout} "$@"; }

      # Inventory: a constant-1 info metric carrying the static facts a topology board
      # joins against (cf. nixos_configuration_revision_info). Keeping description/group/
      # wanted here rather than on the health gauges keeps the gauges lean and gives the
      # "across hosts and users" view one row per repo without hard-coding anything.
      emit '# HELP git_annex_repo_info Static inventory for a git-annex repository (value always 1).'
      emit '# TYPE git_annex_repo_info gauge'
      emit 'git_annex_repo_info{repo="${repoLabel}",user="${userLbl}",description="${promLabel repo.description}",group="${promLabel (orEmpty repo.group)}",wanted="${promLabel (orEmpty repo.wanted)}"} 1'

      ${lib.optionalString repo.assistant ''
        emit '# HELP git_annex_assistant_up Whether the git-annex assistant for this repository is running (1) or not (0).'
        emit '# TYPE git_annex_assistant_up gauge'
        if ${assistantCheck}; then
          emit 'git_annex_assistant_up{repo="${repoLabel}",user="${userLbl}"} 1'
        else
          emit 'git_annex_assistant_up{repo="${repoLabel}",user="${userLbl}"} 0'
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
          emit 'git_annex_remote_reachable{repo="${repoLabel}",user="${userLbl}",remote="${promLabel remote.name}"} 1'
        else
          emit 'git_annex_remote_reachable{repo="${repoLabel}",user="${userLbl}",remote="${promLabel remote.name}"} 0'
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
        emit "git_annex_last_commit_timestamp_seconds{repo=\"${repoLabel}\",user=\"${userLbl}\"} $last_commit"
      fi

      # The exporter's own heartbeat: without it a dead check is indistinguishable from
      # a healthy repo, because the last-published file just sits there reading 1.
      emit '# HELP git_annex_check_timestamp_seconds Unix time this repository health check last completed.'
      emit '# TYPE git_annex_check_timestamp_seconds gauge'
      emit "git_annex_check_timestamp_seconds{repo=\"${repoLabel}\",user=\"${userLbl}\"} $(${pkgs.coreutils}/bin/date +%s)"

      # mktemp makes the file 0600; node-exporter runs as its own user and must READ it.
      # Skip this and the metric is published but never scraped — the panel shows "No
      # data" and nothing anywhere says why.
      ${pkgs.coreutils}/bin/chmod 0644 "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" "$metrics_dir/git-annex-${fileTag}.prom"
    '';
}
