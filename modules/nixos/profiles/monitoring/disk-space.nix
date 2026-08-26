# The fleet disk-space watcher (ADR-0032). Alerts #infra-alerts (via the hookshot webhook)
# when any real filesystem on any node drops below the headroom that node declares in the
# fleet registry as `diskFloorGiB`. The ADR carries the measured case for a per-host space
# floor over a percentage; this header is the implementation detail.
#
# WHY IT IS CENTRAL, NOT PER-HOST. Every other on-host check here reads state the host
# alone can see (systemd unit states, its own textfile metrics). Disk usage is not like
# that: node-exporter already ships `node_filesystem_*` from every node to rk1b's
# VictoriaMetrics, so the measurement exists fleet-wide before this module does. Running
# one querying check on rk1b therefore covers the whole fleet with no new secret anywhere
# — the alternative, a check on each host, would need `infra_alerts_hook_id` keyed for
# five more hosts, and sops here is all-or-nothing per host (AGENTS.md), so that means
# re-keying every secret file and a secrets-repo round-trip to gain nothing.
#
# The usual objection to a central check — it goes blind when the host it watches is
# unreachable — does not bite here. Unreachability is already the Gatus probe's job
# (ADR-0019) and `up == 0`'s. A filling disk is a days-long signal, not a partition-
# sensitive one, and a node that has stopped reporting is a monitoring failure this check
# should not try to also be.
#
# WHAT IT ALERTS ON, AND WHY IT IS NOT A PERCENTAGE. Both the threshold shape and the
# numbers are measured, from 48 days of retained history; disk-space-backtest.py (next to
# this file) re-derives them and prints the alert volume each candidate would have
# produced. In short:
#
#   * A percentage is meaningless across a fleet whose devices span 29 GiB to 451 GiB. At
#     80% used sawtoothShark still has ~90 GiB free and is fine, while rk1a has 5.8 GiB
#     and is one build from death. Backtested, a flat >=80% rule would have held
#     sawtoothShark in alarm for 441 of its 498 observed hours — a permanent siren.
#   * A free-SPACE floor separates the fleet's real squeezes from its comfortable devices
#     cleanly. Every genuinely dangerous episode in the window sat under ~10 GiB free and
#     no comfortable device ever did.
#   * The floor is per-host (`diskFloorGiB`) because it cannot be uniform either: rk1b's
#     SD card idles happily at 13.6 GiB free, so a flat 15 GiB floor would have alarmed
#     on it for 930 of 1155 hours.
#
# Two tiers, both against that one declared number: WARN under `warnMultiplier` x floor,
# CRITICAL under the floor itself. Backtested over the same window they fire ~13 times
# across the whole fleet — and every one of those was a device genuinely under pressure.
#
# DEDUPLICATION IS LOAD-BEARING. The impermanence hosts bind-mount dozens of paths off one
# device, and node-exporter reports each mountpoint separately with identical numbers:
# kelpy publishes 30 series for a single filesystem, rk1a 15. Without `max by (host,
# device)` one full disk on kelpy would arrive as 30 alerts. The selector below is the
# same one the `Disk usage %` panel on the fleet-overview dashboard uses, deliberately —
# so the board and the alert can never disagree about what "full" means. It also drops
# tmpfs (four of five hosts have a tmpfs `/` by design, 1-2 GiB, which is not a disk) and
# the impermanence overlay device.
#
# Quiet semantics match the other watchers: a device must read bad for `failureThreshold`
# consecutive ticks before alerting, a recovery notice is sent when it clears, and there
# are no periodic re-alerts while it stays bad. Crossing WARN -> CRITICAL does re-alert
# once, because the escalation is itself news.
{
  config,
  lib,
  pkgs,
  settings ? null,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-disk-space;

  # `or`-guarded so merely referencing the (kelpy-only) matrix profile does not error on a
  # host that never declares it — rk1b, where this actually runs, is one such host.
  infraAlerts = config.custom.profiles.matrix.infraAlerts or null;
  infraWebhookDefault = if infraAlerts != null then infraAlerts.webhookUrlFile else null;
  infraEnabled = infraAlerts != null && (infraAlerts.enable or false);

  # Shared delivery: in-band to #infra-alerts, falling back to the ADR-0020 push relay if
  # that POST fails. This watcher needs the fallback more than most — two of the eight
  # filesystems it watches are kelpy's, and the webhook it posts to routes through kelpy,
  # so without it a kelpy disk filling up is precisely the alert that cannot be delivered.
  alertPost = import ../../../shared/alert-post.nix { inherit lib pkgs; };

  # Per-host floors, baked from the fleet registry into a shell lookup. A host absent from
  # the registry falls through to `defaultFloorGiB` rather than being silently skipped —
  # an unregistered node filling its disk is exactly the case worth still hearing about.
  nodes = if settings != null then settings.nodes else { };
  floorCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: node: "${name}) echo ${toString (node.diskFloorGiB or cfg.defaultFloorGiB)} ;;"
    ) nodes
  );

  # Shared between both queries so the alert and the dashboard cannot drift apart.
  selector = ''fstype!~"${cfg.excludeFstypes}",device!~"${cfg.excludeDevices}"'';
  hostLabel = ''"host", "$1", "instance", "([^.:]+).*"'';

  availQuery = "max by (host, device) (label_replace(node_filesystem_avail_bytes{${selector}}, ${hostLabel}))";
  pctQuery = "max by (host, device) (label_replace(100 * (1 - node_filesystem_avail_bytes{${selector}} / node_filesystem_size_bytes{${selector}}), ${hostLabel}))";

  checkScript = pkgs.writeShellScript "monitoring-disk-space-check" ''
    set -u
    state="$STATE_DIRECTORY"
    vm=${lib.escapeShellArg cfg.victoriaMetricsUrl}
    threshold=${toString cfg.failureThreshold}
    warnMult=${toString cfg.warnMultiplier}

    ${alertPost.mkPost {
      name = "disk-space";
      inherit (cfg) webhookUrlFile;
      inherit (cfg) outOfBand;
    }}

    # $1 = promql -> TSV of host<TAB>device<TAB>value
    vmq() {
      ${pkgs.curl}/bin/curl -sS -m 15 -G "$vm/api/v1/query" \
        --data-urlencode "query=$1" \
        | ${pkgs.jq}/bin/jq -r '.data.result[]
            | [.metric.host // "?", .metric.device // "?", .value[1]]
            | @tsv'
    }

    floor_for() { # $1 = host -> declared floor in GiB
      case "$1" in
    ${floorCases}
        *) echo ${toString cfg.defaultFloorGiB} ;;
      esac
    }

    avail="$(vmq ${lib.escapeShellArg availQuery})"
    if [ -z "$avail" ]; then
      echo "disk-space: no node_filesystem series in VictoriaMetrics — nothing to check" >&2
      exit 0
    fi
    pct="$(vmq ${lib.escapeShellArg pctQuery})"

    printf '%s\n' "$avail" | while IFS="$(printf '\t')" read -r host device bytes; do
      [ -n "''${host:-}" ] || continue

      floor="$(floor_for "$host")"
      # Integer GiB throughout; the tenth of a GiB in the message is cosmetic only.
      gib="$(${pkgs.gawk}/bin/awk -v b="$bytes" 'BEGIN{printf "%.1f", b/1073741824}')"
      whole="$(${pkgs.gawk}/bin/awk -v b="$bytes" 'BEGIN{printf "%d", b/1073741824}')"
      used="$(printf '%s\n' "$pct" \
        | ${pkgs.gawk}/bin/awk -F'\t' -v h="$host" -v d="$device" \
            '$1==h && $2==d {printf "%.0f", $3; found=1} END{if(!found) printf "?"}')"

      warnAt=$((floor * warnMult))
      if [ "$whole" -lt "$floor" ]; then
        level=critical
      elif [ "$whole" -lt "$warnAt" ]; then
        level=warn
      else
        level=ok
      fi

      tag="$(printf '%s_%s' "$host" "$device" | ${pkgs.coreutils}/bin/tr '/ ' '__')"
      cf="$state/$tag.count"
      rf="$state/$tag.reported"
      reported="$(cat "$rf" 2>/dev/null || echo ok)"

      if [ "$level" = ok ]; then
        rm -f "$cf"
        if [ "$reported" != ok ]; then
          post "✅ [$host] $device recovered — ''${gib} GiB free (''${used}% used), above its ''${floor} GiB floor"
          printf ok > "$rf"
        fi
        continue
      fi

      count="$(cat "$cf" 2>/dev/null || echo 0)"
      count=$((count + 1))
      printf '%s' "$count" > "$cf"
      [ "$count" -ge "$threshold" ] || continue

      # Re-alert only on a genuine escalation (warn -> critical), never as a repeat.
      if [ "$reported" = "$level" ] || { [ "$reported" = critical ] && [ "$level" = warn ]; }; then
        continue
      fi

      if [ "$level" = critical ]; then
        post "🚨 [$host] $device is critically low — ''${gib} GiB free (''${used}% used), under its ''${floor} GiB floor"
      else
        post "⚠️ [$host] $device is low — ''${gib} GiB free (''${used}% used), under ''${warnAt} GiB (floor ''${floor} GiB)"
      fi
      printf '%s' "$level" > "$rf"
    done
  '';
in
{
  options.custom.profiles.monitoring-disk-space = {
    enable = lib.mkEnableOption ''
      the fleet disk-space watcher. Queries VictoriaMetrics for every node's real
      filesystems and alerts #infra-alerts when one drops below the headroom that node
      declares as `diskFloorGiB` in the fleet registry. Enable on the monitoring server
      (rk1b), which already scrapes the fleet; it covers every node from there
    '';

    victoriaMetricsUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8428";
      description = "Base URL of the VictoriaMetrics instance to query (loopback by default).";
    };

    webhookUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = infraWebhookDefault;
      defaultText = lib.literalExpression "config.custom.profiles.matrix.infraAlerts.webhookUrlFile (null if that profile is absent)";
      description = ''
        File holding the #infra-alerts webhook url. rk1b does not run the
        matrix.infraAlerts provisioner, so pass the watcher's gatus-webhook-url
        sops template there, as the other rk1b checks do.
      '';
    };

    defaultFloorGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        Floor applied to a host with no `diskFloorGiB` in the fleet registry. Matches the
        registry's own default so an unregistered node is still watched, not skipped.
      '';
    };

    warnMultiplier = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = ''
        WARN fires under this multiple of the host's floor; CRITICAL under the floor
        itself. 2 is measured: at 3x, rk1b's SD card — which idles at 13.6 GiB free and
        is entirely healthy — would have been in alarm for 930 of 1155 observed hours.
      '';
    };

    outOfBand = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            relayUrl = lib.mkOption { type = lib.types.str; };
            tokenFile = lib.mkOption { type = lib.types.path; };
            topicFile = lib.mkOption { type = lib.types.path; };
          };
        }
      );
      default = alertPost.oobFromWatcher config;
      defaultText = lib.literalExpression "derived from custom.profiles.monitoring-watcher.outOfBand on this host, else null";
      description = ''
        The ADR-0020 push relay to fall back to when the in-band webhook POST fails.
        Defaults to whatever the uptime watcher on this host already declares, so a host
        running it needs no extra wiring and a host without it keeps in-band-only
        behaviour. Set explicitly only to point somewhere else (the VM check does).
      '';
    };

    intervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "How often (seconds) to query VictoriaMetrics.";
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = ''
        Consecutive bad polls before alerting. With the default 900s interval, 4 is a
        one-hour grace. Measured: lengthening it buys almost nothing (a 12-hour debounce
        removed only 2 of 13 episodes over 48 days), so the short, responsive value wins
        — kelpy's root has moved 46 percentage points inside a single day.
      '';
    };

    excludeFstypes = lib.mkOption {
      type = lib.types.str;
      default = "tmpfs|ramfs|overlay|squashfs|vfat";
      description = ''
        Regex of filesystem types to ignore. Kept identical to the fleet-overview
        dashboard's disk panel so the two agree.
      '';
    };

    excludeDevices = lib.mkOption {
      type = lib.types.str;
      default = ".*impermanence.*";
      description = "Regex of devices to ignore (the impermanence overlay).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          infraEnabled || (cfg.webhookUrlFile != null && cfg.webhookUrlFile != infraWebhookDefault);
        message = "custom.profiles.monitoring-disk-space requires either custom.profiles.matrix.infraAlerts.enable or an explicit webhookUrlFile.";
      }
    ];

    systemd.services.monitoring-disk-space-check = {
      description = "Alert when a fleet filesystem drops below its declared headroom";
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "monitoring-disk-space";
        ExecStart = checkScript;
      };
    };

    systemd.timers.monitoring-disk-space-check = {
      description = "Periodic fleet disk-space check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "${toString cfg.intervalSec}s";
        AccuracySec = "30s";
      };
    };
  };
}
