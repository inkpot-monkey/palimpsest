# The hermes overdue-job watcher — ADR-0041, forge inkpotmonkey/property#3. A deterministic
# systemd check in the same tier as the DMARC, secret-expiry and unit-state checks, reading
# hermes's own cron bookkeeping and alerting #infra-alerts when a job has not run when its
# schedule said it would.
#
# ⚠ IT IS DELIBERATELY NOT AN AGENT JOB, and no model is ever involved. ADR-0041: "an agent
# job that watches agent jobs fails silently in exactly the same way". The alert also goes out
# by the hookshot webhook rather than through hermes's own Matrix platform, so a hermes failure
# does not have to depend on hermes being healthy to be reported. Those two facts together are
# the whole value of this file; a later "fold this into a hermes job, it already has a model"
# simplification would delete the watcher and keep only its shadow.
#
# ── WHAT IT READS, AND WHY NOT THE OBVIOUS THING ──────────────────────────────────────────
# The fleet's first agent job is a `--monitor-script` job, and that mode's entire economy is
# that an unchanged monitor output suppresses the model: a quiet day costs no tokens and
# produces NO MESSAGE. So "nothing arrived this morning" is the healthy state, and a watcher
# that read output — its existence, its freshness, its size — would alert on every quiet day
# until it was muted, taking the real signal with it. **Silence is never the signal here.**
#
# What is read instead is hermes's schedule bookkeeping, which moves on every tick whether or
# not anything is said:
#
#   cron/jobs.json             — per job: `next_run_at`, recomputed by the ticker after each
#                                fire. A `next_run_at` that has slid into the past means the
#                                ticker did not fire this job when it said it would. That is
#                                the ticket's whole distinction, in one field.
#   cron/ticker_last_success   — a unix float, rewritten on every completed ticker pass
#                                (~every 30s on rk1b). Stale means the scheduler as a whole is
#                                wedged, which no per-job field can distinguish from a merely
#                                early tick.
#
# ⚠ BOTH FILES LIVE UNDER `$HERMES_HOME/cron/`, not at the top of `$HERMES_HOME`. ADR-0041 and
# docs/agents/agent-jobs.md both say "`jobs.json` under the state directory", which is close
# enough to send you to `/var/lib/hermes/.hermes/jobs.json` — a path that does not exist, and
# whose absence this check would report as "no schedule yet" rather than as an error. The
# paths here were read off the live host, and `hermesHome` stays an option so the VM check can
# point it at a fixture tree.
#
# Deliberately NOT read: `last_status`, `last_error`, `last_failure`, `failure_streak`. A job
# that fires and FAILS is already reported — hermes delivers it through the job's own
# `--failure-deliver`, which the handover checklist points at Infra Alerts. Duplicating that
# here would double every failure while adding nothing, and the gap this watcher closes is
# precisely the one hermes cannot report on its own behalf: the run that never happened.
#
# ── ALERT SEMANTICS ───────────────────────────────────────────────────────────────────────
# Mirrors the unit-state and secret-expiry checks: ONE message when a job (or the ticker)
# first goes overdue, no re-spam while it stays overdue, and a ✅ notice when it recovers.
# Per-subject state lives in $STATE_DIRECTORY, so the timer is idempotent. A job that is
# `enabled = false` or paused is skipped entirely — both are deliberate operator acts, and
# paging about a schedule somebody switched off is how a room gets muted.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-hermes-overdue;

  # Shared delivery (see alert-post.nix): in-band to #infra-alerts, falling back to the
  # ADR-0020 push relay when that POST fails. Picked up automatically on a host whose uptime
  # watcher declares the relay (rk1b does), null everywhere else.
  alertPost = import ../../../shared/alert-post.nix { inherit lib pkgs; };

  host = config.networking.hostName;

  checkScript = pkgs.writeShellScript "monitoring-hermes-overdue-check" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.jq
      ]
    }:$PATH
    state="$STATE_DIRECTORY"
    cron=${lib.escapeShellArg "${cfg.hermesHome}/cron"}
    jobs="$cron/jobs.json"
    ticker="$cron/ticker_last_success"
    grace=${toString cfg.graceSec}
    ticker_stale=${toString cfg.tickerStaleSec}
    now="$(date +%s)"

    ${alertPost.mkPost {
      name = "hermes-overdue";
      inherit (cfg) webhookUrlFile;
      outOfBand = alertPost.oobFromWatcher config;
    }}

    # Seconds -> "3h12m" / "47m" / "22s", for a message a human can act on without doing
    # arithmetic on two ISO timestamps.
    human() {
      local s="$1"
      if   [ "$s" -ge 3600 ]; then printf '%dh%02dm' "$(( s / 3600 ))" "$(( (s % 3600) / 60 ))"
      elif [ "$s" -ge 60 ];   then printf '%dm' "$(( s / 60 ))"
      else                         printf '%ds' "$s"
      fi
    }

    # Edge-triggered alerting. `fire <key> <message>` posts only on the transition into the
    # bad state; `clear <key> <message>` posts only on the transition back out, and only if
    # something was actually fired — so a first run on a healthy host says nothing at all.
    fire() {
      local sf="$state/$1.bad"
      [ -e "$sf" ] && return 0
      : > "$sf"
      post "$2"
    }
    clear_() {
      local sf="$state/$1.bad"
      [ -e "$sf" ] || return 0
      rm -f "$sf"
      post "$2"
    }

    if [ ! -r "$jobs" ]; then
      # No schedule at all. ADR-0041 records the gateway running for days with zero jobs,
      # and that is a legitimate state, not a fault — alerting on it would page the whole
      # window between enabling hermes and handing it its first job.
      echo "hermes-overdue: no $jobs — hermes holds no schedule; nothing to check" >&2
      exit 0
    fi

    # Only jobs that are supposed to run. `enabled=false` and a non-null `paused_at` are
    # both operator decisions, and neither is a missed run.
    active="$(jq -c '[.jobs[]? | select((.enabled == true) and (.paused_at == null))]' "$jobs" 2>/dev/null || echo '[]')"
    [ -n "$active" ] || active='[]'
    n="$(jq 'length' <<<"$active")"
    if [ "$n" -eq 0 ]; then
      echo "hermes-overdue: no enabled, unpaused jobs — nothing to check" >&2
      exit 0
    fi

    # ── The ticker ─────────────────────────────────────────────────────────────────────
    # Checked first and reported separately: a wedged ticker makes EVERY job overdue, and
    # one message naming the cause beats N naming the symptom. The per-job loop still runs
    # after it, so the first jobs to actually miss a slot are still named.
    tick_raw="$(cat "$ticker" 2>/dev/null || true)"
    tick="''${tick_raw%%.*}"
    case "$tick" in
      ""|*[!0-9]*)
        fire ticker "🚨 [${host}] hermes — the cron ticker has recorded no successful pass ($ticker is missing or unreadable), while $n job(s) are scheduled. Nothing is firing; a job whose output is silent by design looks identical to this."
        ;;
      *)
        tick_age=$(( now - tick ))
        if [ "$tick_age" -gt "$ticker_stale" ]; then
          fire ticker "🚨 [${host}] hermes — the cron ticker has not completed a pass in $(human "$tick_age") (threshold $(human "$ticker_stale")). Every scheduled job is stopped, including the ones whose silence is normal."
        else
          clear_ ticker "✅ [${host}] hermes — the cron ticker is completing passes again (last $(human "$tick_age") ago)."
        fi
        ;;
    esac

    # ── Each job's own slot ────────────────────────────────────────────────────────────
    # `next_run_at` is the authority, not `last_run_at`: the ticker rewrites it the moment it
    # fires a job, so it is the one field that says what hermes BELIEVES it still owes. A
    # check written against `last_run_at` plus a cron expression would have to reimplement
    # hermes's own cron parser and timezone handling to say anything at all.
    while IFS=$'\t' read -r id name next last sched tz; do
      [ -n "$id" ] || continue
      if [ -z "$next" ]; then
        # A scheduled job with no next slot is not something this check can judge; say so in
        # the journal rather than inventing a verdict.
        echo "hermes-overdue: job '$name' ($id) has no next_run_at — skipping" >&2
        continue
      fi
      due="$(date -d "$next" +%s 2>/dev/null || true)"
      if [ -z "$due" ]; then
        echo "hermes-overdue: job '$name' ($id) has an unparseable next_run_at '$next' — skipping" >&2
        continue
      fi
      late=$(( now - due ))
      when="$sched"
      [ -n "$tz" ] && when="$sched $tz"
      [ -n "$last" ] || last="never"
      if [ "$late" -gt "$grace" ]; then
        fire "job-$id" "🚨 [${host}] hermes — agent job '$name' ($id) is OVERDUE: it was due at $next, $(human "$late") ago, and has not run (schedule '$when'; last run $last). This is not a quiet day — the scheduler did not fire it. Check \`hermes cron list\` and the hermes-agent unit on ${host}."
      else
        clear_ "job-$id" "✅ [${host}] hermes — agent job '$name' ($id) is running to schedule again (last run $last, next $next)."
      fi
    done < <(jq -r '.[] | [.id, .name, (.next_run_at // ""), (.last_run_at // ""), (.schedule_display // .schedule.expr // ""), (.timezone // "")] | @tsv' <<<"$active")

    # Drop state for jobs that no longer exist, so a deleted job cannot leave a file that
    # suppresses the alert if an id is ever reused.
    for sf in "$state"/job-*.bad; do
      [ -e "$sf" ] || continue
      sid="''${sf##*/job-}"; sid="''${sid%.bad}"
      jq -e --arg i "$sid" 'any(.[]; .id == $i)' <<<"$active" >/dev/null || rm -f "$sf"
    done
    exit 0
  '';
in
{
  options.custom.profiles.monitoring-hermes-overdue = {
    enable = lib.mkEnableOption ''
      the hermes overdue-job watcher (ADR-0041). Reads hermes's own cron bookkeeping and
      alerts #infra-alerts by hookshot webhook when a scheduled agent job has not run when
      it should have, or when the cron ticker itself has stalled. Enable on the host that
      runs the hermes gateway (rk1b); pass a webhookUrlFile (the uptime watcher's
      gatus-webhook-url template on hosts that don't run matrix.infraAlerts).
    '';

    webhookUrlFile = lib.mkOption {
      type = lib.types.path;
      default = config.custom.profiles.monitoring-watcher.webhookUrlFile;
      defaultText = lib.literalExpression "config.custom.profiles.monitoring-watcher.webhookUrlFile";
      description = ''
        File holding the #infra-alerts hookshot webhook url the check posts to. Deliberately
        the webhook and not hermes's own Matrix platform: a hermes failure must not have to
        depend on hermes being healthy to be reported.
      '';
    };

    hermesHome = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes/.hermes";
      description = ''
        `$HERMES_HOME` — the gateway's state directory. The check reads `cron/jobs.json` and
        `cron/ticker_last_success` beneath it. An option rather than a constant so the VM
        check can point it at a fixture tree; the default is what profiles/hermes.nix sets.
      '';
    };

    graceSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600;
      description = ''
        How far past its `next_run_at` a job may sit before it counts as overdue. An hour is
        chosen against a daily job: the ticker runs every ~30s and catches up a missed slot,
        so an hour of lateness is never weather. A sub-daily job would want this lower, at
        which point it belongs per-job rather than per-host.
      '';
    };

    tickerStaleSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = ''
        How long since the cron ticker's last completed pass before the scheduler itself is
        reported stalled. Measured at ~30s between passes on rk1b, so fifteen minutes is
        thirty missed passes — well clear of a slow tick, well inside a daily job's slot.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "*:0/15";
      description = ''
        systemd OnCalendar spec for the check. Quarter-hourly: the thing being watched is a
        missed slot, which does not get worse by being noticed sooner, and a cheap check has
        no reason to be rarer than its own grace period.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.monitoring-hermes-overdue-check = {
      description = "Alert #infra-alerts when a hermes agent job has not run when it should have (ADR-0041)";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-hermes-overdue";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-hermes-overdue-check = {
      description = "Periodic hermes overdue-job check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "2m";
      };
    };
  };
}
