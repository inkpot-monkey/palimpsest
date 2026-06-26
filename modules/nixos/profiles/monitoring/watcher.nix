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
  domain = settings.primaryDomain;

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
        alerts = [ { type = "custom"; } ];
      }
    else
      {
        inherit name;
        group = listenerHost svc;
        url = "tcp://${tsIp (listenerHost svc)}:${toString svc.port}";
        interval = "30s";
        conditions = [ "[CONNECTED] == true" ];
        alerts = [ { type = "custom"; } ];
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
  };

  config = lib.mkIf cfg.enable {
    # The shared webhook id (also used by kelpy's provisioner + unit-state check).
    # rk1b is a recipient of profiles/matrix.yaml (re-keyed), so it decrypts here.
    sops.secrets.infra_alerts_hook_id.sopsFile = matrixSecrets;

    # Build the full webhook URL (capability) into an env file Gatus reads at
    # runtime — keeps the secret hookId out of the world-readable Nix store.
    # Gatus expands ${INFRA_ALERTS_WEBHOOK_URL} in its config when it loads.
    sops.templates."gatus-env".content =
      "INFRA_ALERTS_WEBHOOK_URL=https://hookshot.${domain}/webhook/${config.sops.placeholder.infra_alerts_hook_id}";

    # Pin the Caddy-fronted names to their edge's tailscale IP (tailnet path).
    networking.hosts = hostsByIp;

    services.gatus = {
      enable = true;
      settings = {
        web.port = webPort;
        storage.type = "memory";
        alerting.custom = {
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
        inherit endpoints;
      };
    };

    # Inject the webhook URL secret into Gatus's environment.
    systemd.services.gatus.serviceConfig.EnvironmentFile = config.sops.templates."gatus-env".path;

    # Status page + API, tailnet-only.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ webPort ];
  };
}
