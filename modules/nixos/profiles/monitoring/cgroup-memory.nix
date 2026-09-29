# Per-unit cgroup memory metrics — palimpsest#211, landed by #212.
#
# The fleet had NO memory instrumentation at all before this. That was tolerable while nothing
# was capped; it stopped being tolerable the moment a cap was set, because a cap you cannot
# measure is a number you can only ever guess at. So this module exists to answer one
# question — "how much does this unit actually use, and has it hit its ceiling?" — and it ships
# in the SAME deploy as the first cap, deliberately: a metric that arrives after the thing it
# measures leaves a hole exactly where the interesting data is (the first-boot import, the
# first big clone, the first runaway).
#
# Generic rather than forge-specific, for the same amount of code. Enable it on a host and
# name the units you care about; on kelpy that is the new forge AND the incumbents it shares
# 4 GB with, so the numbers are comparable.
#
# ── What it reads, and what it cannot ─────────────────────────────────────────────────────
# Straight out of the unit's cgroup v2 directory:
#
#   memory.current   bytes charged right now
#   memory.peak      the kernel's own high-water mark since the cgroup was created. This is
#                    the reason a one-minute timer is honest rather than a sampling gamble:
#                    a spike between two polls is missed by `current` and recorded by `peak`.
#   memory.max/high  the ceilings actually in force, read back from the kernel rather than
#                    from the config that was meant to set them
#   memory.events    the kernel's counters: `high` (throttled), `max` (allocation refused),
#                    `oom`, `oom_kill`. `oom_kill` is the one that matters — it is the only
#                    unambiguous "this unit was killed for memory" signal there is.
#
# `memory.pressure` (PSI) is DELIBERATELY not read: it does not exist in kelpy's vpsAdminOS
# container (measured, #211). Nothing here may depend on it.
#
# ── No alert ──────────────────────────────────────────────────────────────────────────────
# Collection only, on purpose. There is no baseline yet, so any threshold would be invented,
# and this stack has no vmalert anyway — an alert here would mean a new webhook check. #211's
# tripwire names what the eventual alert fires on (an `oom_kill` means RAISE the cap; the move
# to rk1b triggers only when the raise would push kelpy under 1 GB available).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-cgroup-memory;
in
{
  options.custom.profiles.monitoring-cgroup-memory = {
    enable = lib.mkEnableOption ''
      per-unit cgroup memory metrics in the node-exporter textfile dir (palimpsest#211).
      Requires the monitoring-exporters profile, which owns metricsDir
    '';

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "forgejo.service"
        "caddy.service"
      ];
      description = ''
        Units to report on, by full unit name. CURATED per host, like
        monitoring-unit-state.units: this is "which processes am I watching the memory of",
        which is a judgement about the host, not something derivable from its config.

        A unit that is not running simply has no cgroup; it is reported as
        `cgroup_memory_cgroup_present 0` rather than skipped, so "stopped" and "misspelt"
        do not look identical in Grafana.
      '';
    };

    metricsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "node-exporter textfile collector directory (see monitoring-exporters).";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1min";
      description = ''
        How often to sample. One minute is cheap (a handful of small reads under /sys) and is
        NOT the resolution of the measurement: `memory.peak` is a kernel-maintained
        high-water mark, so peaks between samples are still caught.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.units != [ ];
        message = "custom.profiles.monitoring-cgroup-memory is enabled but `units` is empty — it would publish an empty metrics file.";
      }
      {
        assertion = config.custom.profiles.monitoring-exporters.enable;
        message = "custom.profiles.monitoring-cgroup-memory needs custom.profiles.monitoring-exporters (it owns the textfile directory the metrics are written to and the node-exporter that scrapes them).";
      }
    ];

    systemd.services.monitoring-cgroup-memory = {
      description = "Export per-unit cgroup memory metrics (palimpsest#211)";
      path = with pkgs; [
        coreutils
        systemd
      ];
      serviceConfig = {
        Type = "oneshot";
        # Root, and no sandbox: the whole job is to read another unit's cgroup directory,
        # which every `Protect*`/`Private*` knob worth setting would hide.
        User = "root";
      };
      script = ''
        set -u
        metrics_dir=${lib.escapeShellArg cfg.metricsDir}

        # Best-effort, exactly like the secret-expiry check: if the textfile dir is not there
        # the exporters profile is not on, and this is a no-op rather than a failed unit.
        if [ ! -d "$metrics_dir" ]; then
          echo "cgroup-memory: metrics dir $metrics_dir absent — nothing to do" >&2
          exit 0
        fi

        tmp="$(mktemp "$metrics_dir/.cgroup-memory.XXXXXX")"
        # `mktemp` makes it 0600; node-exporter runs as its own user and must be able to READ
        # the published file. Without this the metric is written and never scraped — the pane
        # just says "No data" and nothing anywhere reports an error.
        trap 'rm -f "$tmp"' EXIT

        {
          echo '# HELP cgroup_memory_cgroup_present Whether the unit currently has a cgroup (1) or is not running (0).'
          echo '# TYPE cgroup_memory_cgroup_present gauge'
          echo '# HELP cgroup_memory_current_bytes Bytes currently charged to the unit'"'"'s cgroup (memory.current).'
          echo '# TYPE cgroup_memory_current_bytes gauge'
          echo '# HELP cgroup_memory_peak_bytes Kernel high-water mark of memory.current since the cgroup was created (memory.peak).'
          echo '# TYPE cgroup_memory_peak_bytes gauge'
          echo '# HELP cgroup_memory_limit_bytes Memory ceiling in force, read back from the kernel. Absent when unlimited.'
          echo '# TYPE cgroup_memory_limit_bytes gauge'
          echo '# HELP cgroup_memory_events_total Kernel cgroup memory event counters (memory.events): high, max, oom, oom_kill.'
          echo '# TYPE cgroup_memory_events_total counter'
        } >> "$tmp"

        emit_unit() {
          unit="$1"

          # Ask systemd where the cgroup is rather than assuming `system.slice/<unit>`: a
          # templated, sliced or delegated unit does not live there, and guessing would
          # report a healthy-looking 0 for a unit that is in fact running fine elsewhere.
          rel="$(systemctl show "$unit" --property=ControlGroup --value 2>/dev/null || true)"
          dir=""
          if [ -n "$rel" ] && [ -d "/sys/fs/cgroup$rel" ]; then
            dir="/sys/fs/cgroup$rel"
          fi

          if [ -z "$dir" ]; then
            printf 'cgroup_memory_cgroup_present{unit="%s"} 0\n' "$unit" >> "$tmp"
            return 0
          fi
          printf 'cgroup_memory_cgroup_present{unit="%s"} 1\n' "$unit" >> "$tmp"

          gauge() { # $1=metric $2=cgroup file
            [ -r "$dir/$2" ] || return 0
            v="$(cat "$dir/$2" 2>/dev/null || true)"
            # "max" is cgroup v2 for "no limit". Emitting it as a number would be a lie and
            # emitting +Inf makes every `used/limit` ratio NaN, so an unlimited unit simply
            # publishes no limit series at all — `absent()` is the honest query.
            case "$v" in
              '''|max|*[!0-9]*) return 0 ;;
            esac
            printf '%s{unit="%s"} %s\n' "$1" "$unit" "$v" >> "$tmp"
          }

          gauge cgroup_memory_current_bytes memory.current
          gauge cgroup_memory_peak_bytes memory.peak

          # Both ceilings ride one metric name with a `limit` label, so a dashboard can plot
          # current-vs-ceiling without knowing which knobs a given unit happens to set.
          for pair in "max memory.max" "high memory.high"; do
            set -- $pair
            [ -r "$dir/$2" ] || continue
            v="$(cat "$dir/$2" 2>/dev/null || true)"
            case "$v" in
              '''|max|*[!0-9]*) continue ;;
            esac
            printf 'cgroup_memory_limit_bytes{unit="%s",limit="%s"} %s\n' "$unit" "$1" "$v" >> "$tmp"
          done

          # memory.events is `<name> <count>` per line. Emitted wholesale rather than
          # filtered to a known list: the set grows between kernels (oom_group_kill arrived
          # that way), and a counter nobody plots costs a line.
          if [ -r "$dir/memory.events" ]; then
            while read -r name count; do
              [ -n "''${name:-}" ] || continue
              printf 'cgroup_memory_events_total{unit="%s",event="%s"} %s\n' "$unit" "$name" "$count" >> "$tmp"
            done < "$dir/memory.events"
          fi
        }

        ${lib.concatMapStringsSep "\n" (u: "emit_unit ${lib.escapeShellArg u}") cfg.units}

        chmod 0644 "$tmp"
        mv -f "$tmp" "$metrics_dir/cgroup-memory.prom"
        trap - EXIT
      '';
    };

    systemd.timers.monitoring-cgroup-memory = {
      description = "Sample per-unit cgroup memory (palimpsest#211)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.interval;
        Unit = "monitoring-cgroup-memory.service";
      };
    };
  };
}
