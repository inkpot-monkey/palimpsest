# The gluetun tunnel watchdog.
#
# gluetun's failure mode is that it does not fail. When its WireGuard tunnel collapses,
# the gluetun *process* stays up, so systemd reports `active (running)` indefinitely and
# every layer above it — the unit-state check, the reachability probe, podman itself —
# sees a healthy service. Meanwhile the netns has lost its tun0 address and default
# route, the kill-switch firewall (correctly) drops everything that tries to leave via
# eth0, and every container sharing that namespace is silently off the network.
#
# That happened on kelpy: three failed VPN healthchecks in 13 seconds, then two days of
# qBittorrent sitting at 0 DHT nodes with its torrents frozen in metaDL, and slskd timing
# out on every search — all while `systemctl status` was green. Nothing in the stack was
# looking at the one thing that had actually broken.
#
# So this looks at exactly that: does the tunnel interface still carry an IPv4 address?
# It needs no network to test, and it cannot be faked by a process that is merely still
# alive — when the tunnel collapsed, tun0 stayed listed in the netns but lost its address,
# leaving qBittorrent's sockets stranded on a 10.2.0.2 that no longer existed.
#
# It deliberately does NOT check the main routing table. gluetun's WireGuard installs the
# VPN default route via POLICY routing (fwmark + its own table), so `ip route` / the main
# table shows only the podman bridge even when the tunnel is perfectly healthy. A check
# for "default route over tun" therefore reads unhealthy in every state — it looks
# plausible, and it is always red. That mistake shipped here once already.
#
# On failure it restarts podman-gluetun. Because the containers that share the namespace
# are now BindsTo/PartOf that unit (see qbittorrent.nix and slskd.nix), they come back
# with it — a restart of gluetun alone would leave them attached to a destroyed netns.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.media;
  wcfg = cfg.gluetunWatchdog;

  watchdogScript = pkgs.writeShellScript "gluetun-watchdog" ''
    set -u
    state="$STATE_DIRECTORY"
    cf="$state/consecutive-failures"
    lf="$state/last-restart"
    url="$(cat ${lib.escapeShellArg wcfg.webhookUrlFile} 2>/dev/null || true)"
    host="$(${pkgs.inetutils}/bin/hostname)"

    post() { # $1 = message text
      [ -n "$url" ] || return 0
      ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null \
        -H 'content-type: application/json' \
        --data "$(${pkgs.jq}/bin/jq -nc --arg t "$1" '{text:$t}')" \
        "$url" || echo "gluetun-watchdog: failed to POST alert" >&2
    }

    # Healthy == the container is running AND ${wcfg.interface} carries an IPv4 address.
    # Reading interface state rather than making a request keeps this cheap and keeps it
    # honest: a hung DNS lookup would look the same as a dead tunnel.
    #
    # The interface is matched by exact name on purpose. A prefix match on "tun" would
    # also match tunl0/ip6tnl0, which exist in this netns permanently and never hold an
    # IPv4 address.
    healthy() {
      pid="$(${pkgs.podman}/bin/podman inspect --format '{{.State.Pid}}' gluetun 2>/dev/null)" || return 1
      [ -n "$pid" ] && [ "$pid" != "0" ] || return 1
      ${pkgs.util-linux}/bin/nsenter -t "$pid" -n \
        ${pkgs.iproute2}/bin/ip -4 addr show ${lib.escapeShellArg wcfg.interface} 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -q 'inet '
    }

    if healthy; then
      if [ "$(cat "$cf" 2>/dev/null || echo 0)" -ge ${toString wcfg.failureThreshold} ]; then
        echo "gluetun-watchdog: tunnel is healthy again" >&2
        post "✅ [$host] gluetun VPN tunnel recovered — ${wcfg.interface} has an address again"
      fi
      rm -f "$cf"
      exit 0
    fi

    count=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$count" > "$cf"
    echo "gluetun-watchdog: ${wcfg.interface} has no IPv4 address in the gluetun netns ($count/${toString wcfg.failureThreshold})" >&2
    [ "$count" -ge ${toString wcfg.failureThreshold} ] || exit 0

    # Cooldown. If ProtonVPN itself is down, restarting in a loop neither helps nor
    # tells us anything new — it just churns the netns and takes the containers with it.
    now="$(${pkgs.coreutils}/bin/date +%s)"
    last="$(cat "$lf" 2>/dev/null || echo 0)"
    if [ $(( now - last )) -lt ${toString wcfg.cooldownSec} ]; then
      echo "gluetun-watchdog: still unhealthy, but within the ${toString wcfg.cooldownSec}s restart cooldown" >&2
      exit 0
    fi
    printf '%s' "$now" > "$lf"

    echo "gluetun-watchdog: restarting podman-gluetun.service (dependents follow via PartOf)" >&2
    post "🚨 [$host] gluetun VPN tunnel is down (${wcfg.interface} has no address) — restarting podman-gluetun; qBittorrent and slskd restart with it"
    ${pkgs.systemd}/bin/systemctl restart podman-gluetun.service \
      || echo "gluetun-watchdog: restart failed" >&2
  '';

  # The startup gate for containers that join gluetun's namespace.
  #
  # gluetun's container being "up" does not mean its TUNNEL is up — wireguard finishes a
  # second or so later. libtorrent enumerates interfaces once at startup, so a
  # qbittorrent-app that wins that race binds only eth0/lo and never rebinds when tun0
  # appears: outbound TCP still works (connect() takes its source address from the route),
  # but the UDP DHT socket is stranded on the bridge and dht_nodes sits at 0 forever.
  #
  # This matters far more now that the joining containers are PartOf gluetun and restart in
  # lockstep with it, turning an occasional race into one that runs on every restart.
  # Failing rather than proceeding is deliberate: Restart=on-failure then retries until the
  # tunnel is genuinely ready, instead of leaving a half-bound session up.
  tunnelReadyScript = pkgs.writeShellScript "gluetun-tunnel-ready" ''
    set -u
    for i in $(${pkgs.coreutils}/bin/seq 1 ${toString wcfg.readyTimeoutSec}); do
      pid="$(${pkgs.podman}/bin/podman inspect --format '{{.State.Pid}}' gluetun 2>/dev/null)" || pid=""
      if [ -n "$pid" ] && [ "$pid" != "0" ] \
        && ${pkgs.util-linux}/bin/nsenter -t "$pid" -n \
             ${pkgs.iproute2}/bin/ip -4 addr show ${lib.escapeShellArg wcfg.interface} 2>/dev/null \
           | ${pkgs.gnugrep}/bin/grep -q 'inet '; then
        echo "gluetun-tunnel-ready: ${wcfg.interface} has an address after ''${i}s"
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 1
    done
    echo "gluetun-tunnel-ready: ${wcfg.interface} still has no address after ${toString wcfg.readyTimeoutSec}s" >&2
    exit 1
  '';
in
{
  options.custom.profiles.media.gluetunWatchdog = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable && !cfg.testMode;
      defaultText = lib.literalExpression "config.custom.profiles.media.enable && !testMode";
      description = ''
        Watch the gluetun container's tunnel interface for a live IPv4 address and
        restart podman-gluetun when it is gone. On by default wherever the media profile
        runs for real, because gluetun's tunnel can die without the unit ever leaving
        `active` — the failure this exists to catch is specifically a silent one.
      '';
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "tun0";
      description = ''
        The tunnel interface inside the gluetun netns whose address signals a live VPN.
        Matched by exact name — tunl0 and ip6tnl0 also exist in that namespace and never
        carry an IPv4 address, so a prefix match would read healthy forever.
      '';
    };

    readyTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        How long a joining container waits for the tunnel interface to get an address
        before failing its start (and being retried by Restart=on-failure).
      '';
    };

    readyCheck = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = tunnelReadyScript;
      defaultText = lib.literalExpression "<gluetun-tunnel-ready script>";
      description = ''
        Startup gate for containers sharing gluetun's netns. Used as an ExecStartPre so a
        container cannot bind its sockets before the tunnel interface has an address.
      '';
    };

    intervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "How often (seconds) to check the tunnel interface's address.";
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Consecutive unhealthy checks before restarting. Debounces gluetun's own
        legitimate VPN reconnects, which briefly drop the route while re-dialling.
        With the default 120s interval, 3 ≈ a 6-minute grace.
      '';
    };

    cooldownSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = ''
        Minimum seconds between restarts, so a provider-side outage cannot turn this
        into a restart loop that churns the namespace every couple of minutes.
      '';
    };

    webhookUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = config.custom.profiles.matrix.infraAlerts.webhookUrlFile or null;
      defaultText = lib.literalExpression "config.custom.profiles.matrix.infraAlerts.webhookUrlFile";
      description = ''
        File holding the loopback webhook url for #infra-alerts. A self-healing restart
        that nobody hears about is still an invisible failure, so the watchdog announces
        both the restart and the recovery when this is available.
      '';
    };
  };

  config = lib.mkIf wcfg.enable {
    systemd.services.gluetun-watchdog = {
      description = "Restart gluetun when its VPN tunnel has silently died";
      after = [ "podman-gluetun.service" ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "gluetun-watchdog";
        ExecStart = watchdogScript;
      };
    };

    systemd.timers.gluetun-watchdog = {
      description = "Periodic gluetun VPN tunnel check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Well clear of gluetun's own startup dial, so a boot never trips the counter.
        OnBootSec = "5min";
        OnUnitActiveSec = "${toString wcfg.intervalSec}s";
        AccuracySec = "15s";
      };
    };
  };
}
