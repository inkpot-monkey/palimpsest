{
  config,
  lib,
  pkgs,
  settings,
  self,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-server;

  # Dynamically get all defined nodes from settings.nix
  senderNodes = builtins.attrNames settings.nodes;

  # Helper function to generate target strings for a specific port
  makeTargets = port: map (ip: "${ip}:${toString port}") senderNodes;

  dashboards = {
    dmarc = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/11333/revisions/1/download";
      sha256 = "sha256-B0+jcw6L32KftbkyNyhswXar7EzGQuAyU5HH2rSiNts=";
    };
    node-exporter = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/1860/revisions/37/download";
      sha256 = "sha256-1DE1aaanRHHeCOMWDGdOS1wBXxOF84UXAjJzT5Ek6mM=";
    };
  };

  # Construct a directory in the Nix store containing only the strictly cryptographically hashed dashboards
  dashboardsDir = pkgs.runCommand "grafana-dashboards" { } ''
    mkdir -p $out
    ln -s ${dashboards.dmarc} $out/dmarc.json
    ln -s ${dashboards.node-exporter} $out/node-exporter.json
    # In-tree dashboard (not fetched): the secret-expiry gauge (ADR-0031), fed by the
    # secret_expiry_timestamp_seconds textfile metric.
    ln -s ${./dashboards/secret-expiry.json} $out/secret-expiry.json
  '';

  # True when the host has an NVMe /var/cache mount (rk1b) — used to redirect
  # VL/VM data off the eMMC and onto the NVMe partition. See ADR-0028.
  hasNvmeCache = config.fileSystems ? "/var/cache";
in
{
  options.custom.profiles.monitoring-server = {
    enable = lib.mkEnableOption "monitoring server (VictoriaMetrics, Grafana) configuration";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        sops.secrets = {
          grafana_password = {
            sopsFile = self.lib.getSecretFile "monitoring";
            owner = "grafana";
          };
          grafana_secret_key = {
            sopsFile = self.lib.getSecretFile "monitoring";
            owner = "grafana";
          };
        };

        # Pin all node tailscale IPs so VictoriaMetrics can resolve the scrape target
        # hostnames. rk1b has no MagicDNS (acceptDns = false) and no blocky — kelpy had
        # blocky providing runtime resolution when the server lived there (ADR-0028).
        # Nodes without a tailscale entry in settings.nodes (e.g. inactive placeholders)
        # are skipped; their scrape targets will fail regardless.
        networking.hosts = lib.foldlAttrs (
          acc: _name: node:
          let
            ip = node.tailscale.ip4;
          in
          acc // { ${ip} = (acc.${ip} or [ ]) ++ [ node.hostName ]; }
        ) { } (lib.filterAttrs (_: node: node ? tailscale) settings.nodes);

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

        # VictoriaLogs — 30d retention, 20 GiB disk cap
        services.victorialogs = {
          enable = true;
          extraOptions = [
            "-retentionPeriod=30d"
            "-retention.maxDiskSpaceUsageBytes=20GiB"
          ];
        };

        # VictoriaMetrics — 3 month retention, 10 GiB free-space valve
        services.victoriametrics = {
          enable = true;
          listenAddress = "0.0.0.0:8428";
          retentionPeriod = "3";
          extraOptions = [ "-storage.minFreeDiskSpaceBytes=10737418240" ];
          prometheusConfig = {
            scrape_configs = [
              {
                job_name = "node";
                static_configs = [
                  { targets = makeTargets config.services.prometheus.exporters.node.port; }
                ];
              }
            ]
            ++ lib.optionals (config.custom.profiles.monitoring-dmarc.enable or false) [
              {
                job_name = "dmarc";
                static_configs = [
                  { targets = [ "127.0.0.1:${toString config.services.dmarc-metrics-exporter.port}" ]; }
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
              # Marked default so provisioned dashboards resolve their `datasource`
              # template variable without a hard-coded uid. Do NOT add an explicit `uid`
              # here: adding one to an already-provisioned datasource makes Grafana fail
              # provisioning with "data source not found" and crash-loop.
              isDefault = true;
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
              options.path = dashboardsDir;
            }
          ];
        };
      }

      # Grafana state (dashboard selections, plugin data, session DB). VM/VL data is on
      # /var/cache (NVMe) via BindPaths so it survives impermanence without this entry.
      (lib.mkIf config.custom.profiles.impermanence.enable {
        environment.persistence."/persistent".directories = [ "/var/lib/grafana" ];
      })

      # When the host has /var/cache on NVMe (rk1b): redirect VL and VM data dirs
      # onto the NVMe so constant metric/log write IO doesn't touch the eMMC.
      # Uses BindPaths to mount /var/cache/{vl,vm} over the DynamicUser StateDirectory
      # paths — /var/cache dirs are world-writable so any dynamic UID can write there.
      # See ADR-0028 for the retention + disk-cap rationale.
      (lib.mkIf hasNvmeCache {
        systemd.tmpfiles.rules = [
          "d /var/cache/victorialogs 0777 root root -"
          "d /var/cache/victoriametrics 0777 root root -"
          "d /var/cache/victoriametrics/snapshots 0777 root root -"
        ];

        systemd.services.victorialogs = {
          requires = [ "var-cache.mount" ];
          after = [ "var-cache.mount" ];
          serviceConfig.BindPaths = [ "/var/cache/victorialogs:/var/lib/victorialogs" ];
        };

        systemd.services.victoriametrics = {
          requires = [ "var-cache.mount" ];
          after = [ "var-cache.mount" ];
          serviceConfig.BindPaths = [ "/var/cache/victoriametrics:/var/lib/victoriametrics" ];
        };
      })
    ]
  );
}
