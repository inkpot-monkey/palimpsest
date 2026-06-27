# The off-host uptime watcher (Gatus) — ADR-0026. Reachability-probes every
# registered service and alerts to #infra-alerts via the hookshot webhook
# (slice 01). Runs on an always-on host that is NOT the one it watches (rk1b),
# so it can still observe kelpy failing.
#
# Endpoints are DERIVED from settings.services (monitor-by-default): a new service
# is probed automatically. Slice 04 adds per-service opt-out + a flake-check guard.
#
# HOW IT PROBES (learned from live testing, not assumption): the fleet's web
# services bind to LOOPBACK behind kelpy's Caddy edge — their raw ports are NOT
# reachable over Tailscale. The single tailnet-reachable ingress is Caddy on :443.
# So a Caddy-fronted service is probed at `https://<name>.<domain>` THROUGH Caddy
# (a 200/302/404 means Caddy + backend are both up; a 502/503/504 means the backend
# is down — exactly the "host up, service down" case ADR-0026 targets). Private
# services are `internal_only` (tailnet source-IP gated); this watcher is on the
# tailnet, so it passes. Services NOT behind a Caddy edge (e.g. the rk1a LLM) are
# probed by raw TCP to the listener's tailscale IP.
#
# `networking.hosts` below pins each Caddy name to its EDGE's tailscale IP, so both
# the probes and the webhook delivery stay on the tailnet (no public DNS, which
# rk1b's resolver does not serve for the internal subdomains anyway).
{
  config,
  lib,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-watcher;
  matrixSecrets = self.lib.getSecretFile "matrix";
  # The out-of-band publish token lives in the monitoring profile (key `publish_token`),
  # alongside the relay's VAPID + Cloudflare deploy secrets.
  pushRelaySecrets = self.lib.getSecretFile "monitoring";
  domain = settings.primaryDomain;

  # Out-of-band channel (ADR-0027): a second, ntfy-shaped alerter pointed at the
  # self-hosted web-push relay, attached to ONLY the delivery-path endpoints so the
  # phone buzzes when the Matrix path itself is down. Disabled until the relay is
  # live + the publish token is keyed for rk1b (push-relay issue 04).
  oob = cfg.outOfBand;

  # Hosts that run the Caddy edge profile (proxy.nix). Services on a Caddy edge are
  # probed via HTTPS through Caddy; services on any other edge fall back to a raw
  # TCP probe. Shared with the slice-04 guard (single source of truth in settings).
  inherit (settings) caddyEdges;

  # The host that LISTENS on a service (origin when off-edge, else edge) vs the
  # EDGE host (where Caddy + DNS live) — mirrors settings.nix's listenerHost.
  listenerHost = svc: svc.origin or svc.edge;
  edgeHost = svc: svc.edge;
  tsIp = host: settings.nodes.${host}.tailscale.ip4;

  viaCaddy = svc: lib.elem (edgeHost svc) caddyEdges;

  # Monitor-by-default: a service is watched unless it opts out (ADR-0026 slice 04).
  monitored = svc: svc.monitor.enable or true;

  # The hookshot webhook (in-band) rides every endpoint; the out-of-band ntfy/web-push
  # alerter rides only the configured delivery-path endpoints, and only when enabled.
  alertsFor =
    name:
    [ { type = "custom"; } ]
    ++ lib.optional (oob.enable && lib.elem name oob.endpoints) { type = "ntfy"; };

  mkEndpoint =
    name: svc:
    if viaCaddy svc then
      {
        inherit name;
        group = edgeHost svc;
        url = "https://${name}.${domain}";
        interval = "30s";
        # CONNECTED guards the TCP connect to Caddy (a failed connect yields
        # STATUS 0, which would otherwise satisfy `< 500`); STATUS < 500 then
        # fails on a 502/503/504 backend-down through Caddy.
        conditions = [
          "[CONNECTED] == true"
          "[STATUS] < 500"
        ];
        alerts = alertsFor name;
      }
    else
      {
        inherit name;
        group = listenerHost svc;
        url = "tcp://${tsIp (listenerHost svc)}:${toString svc.port}";
        interval = "30s";
        conditions = [ "[CONNECTED] == true" ];
        alerts = alertsFor name;
      };

  allServices = lib.filterAttrs (_: monitored) (
    settings.services.public // settings.services.private
  );
  endpoints = lib.mapAttrsToList mkEndpoint allServices;

  # Caddy-fronted service names must resolve to their EDGE's tailscale IP on this
  # watcher host, so probes (and the hookshot webhook delivery) take the tailnet
  # path to Caddy instead of public DNS. Grouped into networking.hosts (ip -> names).
  caddyServices = lib.filterAttrs (_: viaCaddy) allServices;
  caddyEdgeIps = lib.unique (lib.mapAttrsToList (_: svc: tsIp (edgeHost svc)) caddyServices);
  hostsByIp = lib.listToAttrs (
    map (
      ip:
      lib.nameValuePair ip (
        lib.mapAttrsToList (name: _: "${name}.${domain}") (
          lib.filterAttrs (_: svc: tsIp (edgeHost svc) == ip) caddyServices
        )
      )
    ) caddyEdgeIps
  );

  webPort = 8085;
in
{
  options.custom.profiles.monitoring-watcher = {
    enable = lib.mkEnableOption ''
      the off-host uptime watcher (Gatus). Reachability-probes the fleet's
      registered services and alerts to #infra-alerts via the hookshot webhook
      (ADR-0026). Enable on an always-on host that is NOT the one it watches.
    '';

    outOfBand = {
      enable = lib.mkEnableOption ''
        the out-of-band web-push alerter (ADR-0027): a second, ntfy-shaped Gatus
        alerter pointed at the self-hosted push relay, attached to only the
        delivery-path `endpoints` so the phone is notified when the Matrix path
        itself is down. Enable once the relay is live and `push_relay_publish_token`
        is keyed for this host (push-relay issue 04).
      '';
      relayUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://push.${domain}";
        description = "Base URL of the ntfy-compatible push relay.";
      };
      # topic is NOT a NixOS option — it is a sops secret (key `topic` in
      # monitoring.yaml) injected as $NTFY_TOPIC into the gatus env file, so
      # the phrase never appears in the Nix store or the repo.
      endpoints = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "matrix"
          "hookshot"
        ];
        description = ''
          Service names whose failure fires an out-of-band push — the Matrix
          delivery path (so the phone buzzes exactly when in-band can't deliver).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # The shared webhook id (also used by kelpy's provisioner + unit-state check).
    # rk1b is a recipient of profiles/matrix.yaml (re-keyed), so it decrypts here.
    # The out-of-band publish token is added only when that channel is enabled —
    # enabling it requires monitoring.yaml to be re-keyed for this host too.
    sops.secrets = {
      infra_alerts_hook_id.sopsFile = matrixSecrets;
    }
    // lib.optionalAttrs oob.enable {
      push_relay_publish_token = {
        sopsFile = pushRelaySecrets;
        key = "publish_token";
      };
      push_relay_topic = {
        sopsFile = pushRelaySecrets;
        key = "publish_topic";
      };
    };

    # Build the secret capabilities into an env file Gatus reads at runtime — keeps
    # them out of the world-readable Nix store. Gatus expands ${VAR} when it loads.
    sops.templates."gatus-env".content =
      "INFRA_ALERTS_WEBHOOK_URL=https://hookshot.${domain}/webhook/${config.sops.placeholder.infra_alerts_hook_id}\n"
      + lib.optionalString oob.enable ''
        NTFY_PUBLISH_TOKEN=${config.sops.placeholder.push_relay_publish_token}
        NTFY_TOPIC=${config.sops.placeholder.push_relay_topic}
      '';

    # Pin the Caddy-fronted names to their edge's tailscale IP (tailnet path).
    networking.hosts = hostsByIp;

    services.gatus = {
      enable = true;
      settings = {
        web.port = webPort;
        storage.type = "memory";
        alerting = {
          custom = {
            url = "\${INFRA_ALERTS_WEBHOOK_URL}";
            method = "POST";
            body = ''{"text": "🚨 [ENDPOINT_GROUP]/[ENDPOINT_NAME] [ALERT_TRIGGERED_OR_RESOLVED] [ALERT_DESCRIPTION] [RESULT_ERRORS]"}'';
            # ADR-0026 semantics: 3 consecutive fails (~90s) before alerting,
            # recovery notice on return, no periodic re-alerts.
            default-alert = {
              failure-threshold = 3;
              success-threshold = 2;
              send-on-resolved = true;
            };
          };
        }
        // lib.optionalAttrs oob.enable {
          # Out-of-band: ntfy alerter → the web-push relay (ADR-0027). Same quiet
          # semantics; attached to the delivery-path endpoints only (see alertsFor).
          ntfy = {
            url = oob.relayUrl;
            topic = "\${NTFY_TOPIC}";
            # Gatus validates that the ntfy token looks like a real ntfy access
            # token (a `tk_` prefix) before it will send, so present it that way.
            # The relay accepts the bare token or this prefixed form (authorized()).
            token = "tk_\${NTFY_PUBLISH_TOKEN}";
            default-alert = {
              failure-threshold = 3;
              success-threshold = 2;
              send-on-resolved = true;
            };
          };
        };
        inherit endpoints;
      };
    };

    # Inject the webhook URL secret into Gatus's environment.
    systemd.services.gatus.serviceConfig.EnvironmentFile = config.sops.templates."gatus-env".path;

    # Status page + API, tailnet-only.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ webPort ];
  };
}
