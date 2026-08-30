# ProtonVPN port forwarding, and the wiring that makes qBittorrent actually use it.
#
# Without an inbound port a BitTorrent client is *unconnectable*: it can only ever talk to
# peers it dials out to itself, and it is invisible to everyone else in the swarm. That is
# not a theoretical penalty. On kelpy it looked like this — every torrent complete-or-
# crawling, `connection_status: connected`, DHT healthy at 368 nodes, and 0 B/s of upload
# across thirteen torrents that had been seeding for days; the one still-downloading
# torrent sat in `stalledDL` at 69% with `availability: 0.69`, because the peers holding
# the missing third could not reach us and we had not happened to dial them.
#
# The obvious fix — publish 6881 on the host — is the wrong one, and ./qbittorrent.nix
# explains why: qBittorrent's traffic exits via the VPN, so a host publish binds kelpy's
# real address and hands a BitTorrent handshake to anything that connects, which is
# exactly the leak that was removed in e19c9fe. The right inbound port is one on the VPN
# side, and ProtonVPN hands those out over NAT-PMP.
#
# So this does two things:
#
#   1. Turns on gluetun's port forwarding (`VPN_PORT_FORWARDING`). gluetun asks the
#      ProtonVPN gateway for a port over NAT-PMP, opens it in its own firewall, renews the
#      lease every ~45s, and writes the current number to a status file.
#   2. Copies that number into qBittorrent's listener. This step is unavoidable and is the
#      part that gets forgotten: the assigned port is *dynamic* and is chosen by Proton, so
#      a statically configured `Session\Port` is wrong the moment the lease is issued. A
#      forwarded port that nothing listens on is worth exactly as much as no forwarded port.
#
# PREREQUISITE, and the most likely reason this silently does nothing: ProtonVPN only
# answers NAT-PMP for credentials that were issued with port forwarding enabled. For
# WireGuard that is the "NAT-PMP (Port Forwarding)" toggle at the moment the config is
# generated — an existing key made without it cannot be upgraded in place, it has to be
# regenerated and re-sopsed into `profiles/media.yaml`. `PORT_FORWARD_ONLY=on` in
# ./qbittorrent.nix restricts server selection to servers that support forwarding, which
# is necessary but not sufficient. If gluetun logs a NAT-PMP refusal, the key is the cause.
{
  config,
  lib,
  pkgs,
  settings,
  self,
  ...
}:

let
  cfg = config.custom.profiles.media;
  pcfg = cfg.portForward;

  # gluetun's status file, seen from each side of the mount. The host half lives in /run
  # on purpose: the forwarded port is lease-scoped state that is meaningless once gluetun
  # is gone, and a stale number surviving a reboot would be worse than no number at all.
  hostStatusDir = "/run/gluetun";
  containerStatusDir = "/tmp/gluetun";
  statusFileName = "forwarded_port";
  hostStatusFile = "${hostStatusDir}/${statusFileName}";

  # The WebUI as reached from the host: the loopback publish in ./qbittorrent.nix. Going in
  # via the published port rather than nsenter'ing the netns keeps this a plain HTTP client
  # with no privileged namespace games, and it is the same path Caddy uses.
  api = "http://127.0.0.1:${toString pcfg.webuiPort}";

  syncScript = pkgs.writeShellScript "qbittorrent-port-forward-sync" ''
    set -u
    jar="$RUNTIME_DIRECTORY/cookies"
    pw="$RUNTIME_DIRECTORY/password"

    port="$(${pkgs.coreutils}/bin/cat ${hostStatusFile} 2>/dev/null || true)"
    case "$port" in
      "" | 0)
        # Not an error. gluetun writes the file once the lease is granted, so this is the
        # normal state for the first few seconds after a reconnect — and the permanent
        # state if the ProtonVPN credentials lack the NAT-PMP grant (see the header).
        echo "qbittorrent-port-forward: gluetun has not published a forwarded port yet"
        exit 0
        ;;
      *[!0-9]*)
        echo "qbittorrent-port-forward: ${hostStatusFile} holds a non-numeric value" >&2
        exit 1
        ;;
    esac

    # Reachability is checked before authentication so that a tick landing mid-restart is
    # not reported as a failure: podman-qbittorrent-app being down is the unit-state
    # check's job to alert on, and duplicating it here would just add a second alarm for
    # one fault. A refused connection is transient; bad credentials are not.
    if ! ${pkgs.curl}/bin/curl -sS -m 10 -o /dev/null "${api}/api/v2/app/version" 2>/dev/null; then
      echo "qbittorrent-port-forward: WebUI not answering on ${api} — skipping this tick"
      exit 0
    fi

    # The password reaches curl through a file, never through argv: this runs every few
    # minutes on a host with other logins, and `ps` is world-readable. `tr -d` strips the
    # trailing newline sops leaves on the value, which would otherwise be url-encoded into
    # the form field and rejected.
    ${pkgs.coreutils}/bin/install -m 0600 /dev/null "$pw"
    ${pkgs.coreutils}/bin/tr -d '\n' < ${config.sops.secrets.qbittorrent_webui_password.path} > "$pw"

    if ! ${pkgs.curl}/bin/curl -sS -m 10 -c "$jar" \
           -d "username=${pcfg.webuiUsername}" \
           --data-urlencode "password@$pw" \
           "${api}/api/v2/auth/login" | ${pkgs.gnugrep}/bin/grep -qx 'Ok.'; then
      echo "qbittorrent-port-forward: WebUI login failed for user ${pcfg.webuiUsername}" >&2
      exit 1
    fi

    current="$(${pkgs.curl}/bin/curl -sS -m 10 -b "$jar" "${api}/api/v2/app/preferences" \
      | ${pkgs.jq}/bin/jq -r '.listen_port // empty')"
    if [ -z "$current" ]; then
      echo "qbittorrent-port-forward: could not read listen_port from the WebUI" >&2
      exit 1
    fi

    # Idempotent by design: this runs on a timer, so the common case is "already correct"
    # and must be silent and free.
    [ "$current" = "$port" ] && exit 0

    if ! ${pkgs.curl}/bin/curl -sS -m 10 -b "$jar" -o /dev/null \
           --data-urlencode "json={\"listen_port\":$port}" \
           "${api}/api/v2/app/setPreferences"; then
      echo "qbittorrent-port-forward: failed to set listen_port to $port" >&2
      exit 1
    fi
    echo "qbittorrent-port-forward: listen port $current -> $port (ProtonVPN forwarded)"
  '';
in
{
  options.custom.profiles.media.portForward = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable && !cfg.testMode;
      defaultText = lib.literalExpression "config.custom.profiles.media.enable && !testMode";
      description = ''
        Ask ProtonVPN for a forwarded port via gluetun's NAT-PMP client and keep
        qBittorrent's listener pointed at it. Off in test mode, where there is no real VPN
        to forward through and no secret to authenticate with.
      '';
    };

    webuiUsername = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = ''
        WebUI account the sync job authenticates as. qBittorrent has no scoped API tokens,
        so this is the admin account; its password is read from sops rather than being
        bypassed with `WebUI\LocalHostAuth=false`, because podman's published-port DNAT
        makes host traffic arrive from the bridge address, and "trust localhost" would
        therefore have meant trusting every process on kelpy.
      '';
    };

    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = settings.services.private.torrent.port;
      defaultText = lib.literalExpression "settings.services.private.torrent.port";
      description = "Loopback port the qBittorrent WebUI is published on by ./qbittorrent.nix.";
    };

    intervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        How often to reconcile qBittorrent's listener with the forwarded port. The lease
        renews every ~45s but the number only moves when gluetun reconnects, so this is a
        convergence bound on a rare event, not a poll of a fast-changing value.
      '';
    };
  };

  config = lib.mkIf pcfg.enable {
    # Must exist before gluetun starts, or podman creates it root-owned with the wrong
    # mode as an implicit bind-mount source.
    systemd.tmpfiles.rules = [
      "d ${hostStatusDir} 0755 root root -"
    ];

    virtualisation.oci-containers.containers.gluetun = {
      environment = {
        VPN_PORT_FORWARDING = "on";
        # Spelled out rather than left to the default, so the mount below and the reader
        # above are visibly talking about the same file.
        VPN_PORT_FORWARDING_STATUS_FILE = "${containerStatusDir}/${statusFileName}";
      };
      volumes = [ "${hostStatusDir}:${containerStatusDir}" ];
    };

    # kelpy is a recipient of the user secrets file (secrets/.sops.yaml), so the WebUI
    # password is readable here without duplicating it into a profile secret.
    sops.secrets.qbittorrent_webui_password = {
      sopsFile = self.lib.getUserSecretFile "inkpotmonkey";
      key = "admin@torrent.palebluebytes.space";
    };

    systemd.services.qbittorrent-port-forward = {
      description = "Point qBittorrent's listener at the ProtonVPN forwarded port";
      after = [ "podman-qbittorrent-app.service" ];
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "qbittorrent-port-forward";
        RuntimeDirectoryMode = "0700";
        ExecStart = syncScript;
      };
    };

    systemd.timers.qbittorrent-port-forward = {
      description = "Periodic qBittorrent forwarded-port reconciliation";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # After the tunnel-ready gate and gluetun's first NAT-PMP round trip, so a boot
        # does not open with a "no forwarded port yet" line every time.
        OnBootSec = "6min";
        OnUnitActiveSec = "${toString pcfg.intervalSec}s";
        AccuracySec = "15s";
      };
    };
  };
}
