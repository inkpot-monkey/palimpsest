# qBittorrent's policy settings, declared in Nix and reconciled onto the running client.
#
# qBittorrent has no declarative configuration. Its settings live in a mutable INI inside
# container state that the application rewrites for itself, so anything set here by hand
# is invisible to the repo, survives no rebuild-from-scratch, and drifts silently. The
# queue limits are the case that made this matter.
#
# Stock qBittorrent allows 3 active downloads and 5 active torrents, and a COMPLETED
# torrent that is still seeding holds one of those five slots forever. On kelpy that
# arithmetic quietly became the throughput ceiling: twelve finished torrents seeding
# against no inbound port (so their ratios could never reach a limit that might retire
# them), five slots permanently consumed, and five queued episodes sitting at 0% behind
# them for hours reading as "stalled" in the UI while nothing was wrong with the stack.
#
# `dont_count_slow_torrents` is the setting that actually addresses that — an idle seeder
# (under `slow_torrent_*_rate_threshold` for `slow_torrent_inactive_timer` seconds) stops
# counting against the limits — and raising the caps alone would only have moved the wall.
# It is exactly the kind of non-obvious, reasoned-about value that must not live only in
# a WebUI checkbox.
#
# OWNERSHIP BOUNDARY, and the trap this creates. Every key declared here is reconciled
# on a timer, so a change made in the WebUI to one of them is reverted within minutes;
# every key NOT declared here stays the WebUI's to own. That is the intended split, but it
# is only kind if the declared set stays small and deliberate — a full dump of qBittorrent's
# ~200 preferences would freeze the whole UI without anyone deciding to.
#
# Unknown keys are the other trap: setPreferences silently ignores anything it does not
# recognise and still answers 200, so a typo would look applied forever. The reconciler
# therefore reads the settings back and fails the unit when a declared key did not take.
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
  qcfg = cfg.qbittorrent;

  api = "http://127.0.0.1:${toString settings.services.private.torrent.port}";

  client = (import ../../../shared/qbittorrent-api.nix { inherit lib pkgs; }).mkClient {
    inherit api;
    username = cfg.portForward.webuiUsername;
    passwordFile = config.sops.secrets.qbittorrent_webui_password.path;
  };

  desired = builtins.toJSON qcfg.preferences;

  reconcileScript = pkgs.writeShellScript "qbittorrent-preferences-reconcile" ''
    set -u
    ${client}

    if ! qbt_up; then
      echo "qbittorrent-preferences: WebUI not answering on ${api} — skipping this tick"
      exit 0
    fi
    qbt_login || exit 1

    desired=${lib.escapeShellArg desired}

    current="$(qbt_get app/preferences)" || exit 1
    # Only the keys that actually differ are sent, so the steady state is one GET and no
    # write at all — this runs on a timer and the common case is "already correct".
    drift="$(${pkgs.jq}/bin/jq -nc --argjson d "$desired" --argjson c "$current" \
      '$d | with_entries(select(.value != $c[.key]))')"
    [ "$drift" = "{}" ] && exit 0

    qbt_post app/setPreferences "json=$drift" || {
      echo "qbittorrent-preferences: setPreferences rejected $drift" >&2
      exit 1
    }
    echo "qbittorrent-preferences: applied $drift"

    # Read back rather than trust the 200: an unrecognised key is accepted and dropped,
    # which would otherwise leave a declared value permanently unapplied and unreported.
    after="$(qbt_get app/preferences)" || exit 1
    rejected="$(${pkgs.jq}/bin/jq -nc --argjson d "$desired" --argjson c "$after" \
      '$d | with_entries(select(.value != $c[.key])) | keys')"
    if [ "$rejected" != "[]" ]; then
      echo "qbittorrent-preferences: qBittorrent did not take $rejected — unknown key or rejected value" >&2
      exit 1
    fi
  '';
in
{
  options.custom.profiles.media.qbittorrent = {
    preferences = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.bool
          lib.types.int
          lib.types.str
        ]
      );
      default = {
        # Queue policy. See the header: the stock values let idle seeders hold every
        # active slot, which is what "stalled" looked like on kelpy.
        queueing_enabled = true;
        dont_count_slow_torrents = true;
        max_active_downloads = 5;
        max_active_torrents = 10;
        max_active_uploads = 5;
      };
      example = lib.literalExpression "{ max_active_downloads = 3; }";
      description = ''
        WebUI preference keys (as named by qBittorrent's `/api/v2/app/preferences`) held
        at these values by a reconciling timer. Keep this set small and deliberate: a key
        listed here can no longer be changed from the WebUI — the next tick puts it back —
        while every key left out stays the WebUI's to own.
      '';
    };

    preferencesIntervalSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "How often to reconcile the declared preferences with the running client.";
    };
  };

  config = lib.mkIf (cfg.enable && !cfg.testMode) {
    assertions = [
      {
        assertion = !(qcfg.preferences ? listen_port);
        message = ''
          custom.profiles.media.qbittorrent.preferences declares `listen_port`, which is
          owned by custom.profiles.media.portForward: ProtonVPN assigns that number
          dynamically over NAT-PMP and the two reconcilers would overwrite each other
          every few minutes (ADR-0033). Drop it here.
        '';
      }
    ];

    # Shared with the forwarded-port sync — declared in both places so neither module
    # depends on the other being enabled.
    sops.secrets.qbittorrent_webui_password = {
      sopsFile = self.lib.getUserSecretFile "inkpotmonkey";
      key = "admin@torrent.palebluebytes.space";
    };

    systemd.services.qbittorrent-preferences = {
      description = "Reconcile qBittorrent's preferences with the declared set";
      after = [ "podman-qbittorrent-app.service" ];
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "qbittorrent-preferences";
        RuntimeDirectoryMode = "0700";
        ExecStart = reconcileScript;
      };
    };

    systemd.timers.qbittorrent-preferences = {
      description = "Periodic qBittorrent preference reconciliation";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "6min";
        OnUnitActiveSec = "${toString qcfg.preferencesIntervalSec}s";
        AccuracySec = "15s";
      };
    };
  };
}
