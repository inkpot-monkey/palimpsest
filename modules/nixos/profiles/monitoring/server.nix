{
  config,
  lib,
  pkgs,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-server;

  # Dynamically get all defined nodes from settings.nix
  senderNodes = builtins.attrNames settings.nodes;

  # Helper function to generate target strings for a specific port
  makeTargets = port: map (ip: "${ip}:${toString port}") senderNodes;
in
{
  options.custom.profiles.monitoring-server = {
    enable = lib.mkEnableOption "monitoring server (VictoriaMetrics, Grafana) configuration";
  };

  config = lib.mkIf cfg.enable {
    sops.secrets = {
      grafana_password.owner = "grafana";
      grafana_secret_key.owner = "grafana";
    };

    # Open ports for monitoring
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
      8428 # VictoriaMetrics
      9428 # VictoriaLogs
      3001 # Grafana
      9115 # Blackbox Exporter
    ];

    # Blackbox Exporter
    services.prometheus.exporters.blackbox = {
      enable = true;
      configFile = pkgs.writeText "blackbox.yml" (
        builtins.toJSON {
          modules = {
            icmp = {
              prober = "icmp";
            };
          };
        }
      );
    };

    # VictoriaLogs
    services.victorialogs.enable = true;

    # VictoriaMetrics
    services.victoriametrics = {
      enable = true;
      listenAddress = "0.0.0.0:8428";
      retentionPeriod = "12";
      prometheusConfig = {
        scrape_configs = [
          {
            job_name = "node";
            static_configs = [
              { targets = makeTargets config.services.prometheus.exporters.node.port; }
            ];
          }
        ];
      };
    };

    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "0.0.0.0";
          http_port = settings.services.private.monitoring.port;
        };
        security = {
          admin_password = "$__file{${config.sops.secrets.grafana_password.path}}";
          secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
        };
      };
      declarativePlugins = with pkgs.grafanaPlugins; [ victoriametrics-logs-datasource ];
      provision.datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://localhost:8428";
        }
        {
          name = "VictoriaLogs";
          type = "victoriametrics-logs-datasource";
          access = "proxy";
          url = "http://localhost:9428";
        }
      ];
      provision.dashboards.settings.providers = [
        {
          name = "My Dashboards";
          options.path = ./dashboards;
        }
      ];
    };
  };
}
