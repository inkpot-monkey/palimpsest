# The off-host uptime watcher (Gatus) — ADR-0026. Reachability-probes every
# registered service over Tailscale and alerts to #infra-alerts via the hookshot
# webhook (slice 01). Runs on an always-on host that is NOT the one it watches
# (rk1b), so it can still observe kelpy failing.
#
# Endpoints are DERIVED from settings.services (monitor-by-default): a new service
# is probed automatically. Slice 04 adds per-service opt-out + a flake-check guard.
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

  # The host that actually LISTENS on a service (origin when off-edge, else edge),
  # and its tailscale IP — mirrors settings.nix's listenerHost.
  listenerHost = svc: svc.origin or svc.edge;
  svcIp = svc: settings.nodes.${listenerHost svc}.tailscale.ip4;

  mkEndpoint = name: svc: {
    inherit name;
    group = listenerHost svc;
    url = "tcp://${svcIp svc}:${toString svc.port}";
    interval = "30s";
    conditions = [ "[CONNECTED] == true" ];
    alerts = [ { type = "custom"; } ];
  };

  allServices = settings.services.public // settings.services.private;
  endpoints = lib.mapAttrsToList mkEndpoint allServices;

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
    # Must be re-keyed to include this host as a sops recipient.
    sops.secrets.infra_alerts_hook_id.sopsFile = matrixSecrets;

    # Build the full webhook URL (capability) into an env file Gatus reads at
    # runtime — keeps the secret hookId out of the world-readable Nix store.
    # Gatus expands ${INFRA_ALERTS_WEBHOOK_URL} in its config when it loads.
    sops.templates."gatus-env".content =
      "INFRA_ALERTS_WEBHOOK_URL=https://hookshot.${settings.primaryDomain}/webhook/${config.sops.placeholder.infra_alerts_hook_id}";

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
