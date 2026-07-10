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

  # Scrape targets by MagicDNS name (`<host>.<tailnet>`), resolved live by blocky's
  # ts.net forward — NOT pinned tailscale IPs, which rot when a host re-keys. DNS is
  # case-insensitive, so the camelCase node names resolve fine.
  makeTargets = port: map (name: "${name}.${settings.tailnet}:${toString port}") senderNodes;

  dashboards = {
    node-exporter = pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/1860/revisions/37/download";
      sha256 = "sha256-1DE1aaanRHHeCOMWDGdOS1wBXxOF84UXAjJzT5Ek6mM=";
    };
  };

  # Construct a directory in the Nix store containing only the strictly cryptographically hashed dashboards
  dashboardsDir = pkgs.runCommand "grafana-dashboards" { } ''
    mkdir -p $out
    # In-tree "Email" board: a DMARC section (dmarc_total/dmarc_compliant_total/…, seeded
    # from the dmarc-metrics-exporter v1.3.1 sample) plus an SMTP TLS Reporting section
    # (smtp_tls_report_* from the monitoring-tlsrpt poller's textfile metrics). Datasource
    # pinned to the default VictoriaMetrics source. Full house-style migration is tracked
    # separately (#30); the board keeps its legacy uid so it updates in place.
    ln -s ${./dashboards/email.json} $out/email.json
    ln -s ${dashboards.node-exporter} $out/node-exporter.json
    # Fleet overview: host up/down, config-revision drift, per-host NixOS state, Gatus
    # probes, and the secret-expiry list (fed by node-exporter + the nixos-metrics
    # textfile collector + the gatus scrape job + the secret_expiry_timestamp_seconds
    # textfile metric). The former standalone secret-expiry board folded into its
    # "Secret expiry" panel (ADR-0031).
    ln -s ${./dashboards/fleet-overview.json} $out/fleet-overview.json
  '';

  # True when the host has an NVMe /var/cache mount (rk1b) — used to redirect
  # VL/VM data off the eMMC and onto the NVMe partition. See ADR-0021.
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

        # No static host pins needed: scrape targets are MagicDNS names
        # (`<host>.<tailnet>`, see makeTargets) resolved live by rk1b's own blocky,
        # which forwards the ts.net zone to tailscale's resolver. A re-keyed host is
        # picked up on the next scrape with no config change (ADR-0021/0023).

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
            ]
            # Gatus emits Prometheus metrics on its own web port when the watcher
            # profile is co-located here (rk1b). It binds loopback, so scrape it over
            # 127.0.0.1 — no need to open it on the tailnet. Port mirrors the
            # `webPort` in watcher.nix.
            ++ lib.optionals (config.custom.profiles.monitoring-watcher.enable or false) [
              {
                job_name = "gatus";
                metrics_path = "/metrics";
                static_configs = [
                  { targets = [ "127.0.0.1:${toString config.services.gatus.settings.web.port}" ]; }
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
      # See ADR-0021 for the retention + disk-cap rationale.
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
