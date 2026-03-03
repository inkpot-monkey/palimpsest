# VictoriaMetrics + Grafana monitoring stack
{
  config,
  pkgs,
  lib,
  ...
}:

let
  dashboardsDir = ./dashboards;
in
{
  imports = [
    ./exporters.nix
    ./logging.nix
    ./restic-exporter.nix
  ];

  sops.secrets = {
    restic-password.owner = "restic-exporter";
    restic_repo.owner = "restic-exporter";
    grafana_password.owner = "grafana";
    grafana_secret_key.owner = "grafana";
  };

  # VictoriaMetrics
  services.victoriametrics = {
    enable = true;
    retentionPeriod = "12"; # Months
    prometheusConfig = {
      scrape_configs = [
        {
          job_name = "node";
          static_configs = [
            { targets = [ "localhost:${toString config.services.prometheus.exporters.node.port}" ]; }
          ];
        }
        {
          job_name = "systemd";
          static_configs = [
            { targets = [ "localhost:${toString config.services.prometheus.exporters.systemd.port}" ]; }
          ];
        }
        {
          job_name = "smartctl";
          static_configs = [
            { targets = [ "localhost:${toString config.services.prometheus.exporters.smartctl.port}" ]; }
          ];
        }
        {
          job_name = "blackbox";
          metrics_path = "/probe";
          params = {
            module = [ "icmp" ];
          };
          static_configs = [
            {
              targets = [
                "google.com"
                "cloudflare.com"
                "1.1.1.1"
                "8.8.8.8"
              ];
            }
          ];
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "localhost:${toString config.services.prometheus.exporters.blackbox.port}";
            }
          ];
        }
        {
          job_name = "restic";
          static_configs = [
            { targets = [ "localhost:8567" ]; }
          ];
        }
      ];
    };
  };
  systemd.services.victoriametrics.serviceConfig.DynamicUser = lib.mkForce false;

  # Grafana
  services.grafana = {
    enable = true;
    settings.server.http_port = 3001;
    settings.security.admin_password = "$__file{${config.sops.secrets.grafana_password.path}}";
    settings.security.secret_key = "$__file{${config.sops.secrets.grafana_secret_key.path}}";
    declarativePlugins = with pkgs.grafanaPlugins; [ victoriametrics-logs-datasource ];
    provision.datasources.settings.datasources = [
      {
        name = "Prometheus"; # VictoriaMetrics is Prometheus-compatible
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
        options.path = "/etc/dashboards";
      }
    ];
  };
  # Dashboard files
  environment = {
    etc = {
      "dashboards/node-exporter.json".source = dashboardsDir + "/node-exporter.json";
      "dashboards/smartctl.json".source = dashboardsDir + "/smartctl.json";
      "dashboards/restic-exporter.json".source = dashboardsDir + "/restic-exporter.json";

      "dashboards/blackbox.json".source =
        pkgs.runCommand "blackbox.json"
          {
            src = pkgs.fetchurl {
              url = "https://grafana.com/api/dashboards/7587/revisions/3/download";
              sha256 = "1b4gi7fv2kvsz9aajz0p84bj1rhk359ahyjvfx8d4bg2g2w3nh6f";
            };
          }
          ''
            sed -E 's/\$\{DS_[A-Z0-9_-]+\}/Prometheus/g' $src > $out
          '';
    };
  };

  # System users for monitoring services
  users.users.victoriametrics = {
    isSystemUser = true;
    group = "users";
  };

  environment.persistence."/persistent".directories = [
    {
      directory = "/var/lib/victoriametrics";
      user = "victoriametrics";
      group = "users";
      mode = "0700";
    }
    {
      directory = "/var/lib/grafana";
      user = "grafana";
      group = "grafana";
      mode = "0750";
    }
  ];
}
