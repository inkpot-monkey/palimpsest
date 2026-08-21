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

  # Scrape targets by MagicDNS name (`<host>.<tailnet>`), resolved live by blocky's
  # ts.net forward — NOT pinned tailscale IPs, which rot when a host re-keys. DNS is
  # case-insensitive, so the camelCase node names resolve fine.
  #
  # One static_config per host so each carries a `presence` label (always-on /
  # on-demand, from settings.nodes — CONTEXT.md, ADR-0026). That label rides onto `up`
  # and every series the target emits, letting boards derive alert-worthiness by
  # presence (an on-demand host being unreachable is expected, never a fault). A node
  # without an explicit presence defaults to on-demand (fail-safe-quiet).
  #
  # `presence` is a property of the HOST, not of the job, so it rides EVERY host-scoped
  # job — ADR-0026 named the node job only because it was then the only one.
  #
  # Takes the host list rather than always walking settings.nodes: the host-scoped jobs
  # below cover different subsets (every node for node-exporter, the fleet resolvers for
  # blocky) and must label their targets identically, or the boards' instance→host
  # rewrite would work on one job and not the other. A host that isn't a registered node
  # has no MagicDNS name to scrape, so say that rather than dying on a missing attribute.
  makeTargets =
    port: hosts:
    map (
      name:
      assert lib.assertMsg (settings.nodes ? ${name})
        "monitoring: scrape target `${name}` is not a registered node (settings.nodes), so it has no MagicDNS name to scrape";
      {
        targets = [ "${name}.${settings.tailnet}:${toString port}" ];
        labels = {
          presence = settings.nodes.${name}.presence or "on-demand";
        };
      }
    ) hosts;

  allNodes = lib.attrNames settings.nodes;

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
    # Fleet Overview: the HOSTS board (services live on Per-Service Health below).
    # Presence-aware host up/down (always-on hosts alarm red, on-demand ones never do),
    # config-revision drift, a failed-units canary, the per-host NixOS lifecycle table
    # (status/uptime/last-online/generations/store/config-age/rev), and the secret-expiry
    # list (fed by node-exporter with the `presence` scrape label + the nixos-metrics
    # textfile collector + the secret_expiry_timestamp_seconds textfile metric). The
    # former standalone secret-expiry board folded into its "Secret expiry" panel
    # (ADR-0031).
    ln -s ${./dashboards/fleet-overview.json} $out/fleet-overview.json
    # Host Drill-Down: curated ~16-panel single-host incident view (CPU/mem/disk/IO/net/
    # temps/failed-units) in the house style, driven by a $host template variable so one
    # board serves any node. The house-conformant replacement for the imported ~200-panel
    # Node Exporter Full board (1860), which is demoted to the "Advanced" folder below (#35).
    ln -s ${./dashboards/host-drill-down.json} $out/host-drill-down.json
    # Logs: fleet-wide VictoriaLogs board (glance error/warning/volume tiles, log volume by
    # host, actionable rate by level, top noisy units, and an errors+warnings live tail),
    # driven by the victoriametrics-logs-datasource plugin over LogsQL. Host + level filter
    # template vars; the $host var is sourced from Prometheus label_values (short name) so it
    # matches the log `host` stream field. The first log-driven board (#36).
    ln -s ${./dashboards/logs.json} $out/logs.json
    # Per-Service Health: app-level health of the self-hosted services, beyond the
    # Gatus up/down dot. Three orthogonal per-service signals — systemd unit-state
    # (node_systemd_unit_state, the curated ADR-0019 expected-up set incl. internal
    # infra no other board graphs), Gatus probe latency + TLS cert expiry, and per-unit
    # log error-rate (Vector→VictoriaLogs) — as a status grid + latency/cert + error
    # panels. Graduated from map #30's fog (#38).
    ln -s ${./dashboards/per-service-health.json} $out/per-service-health.json
    # Backups: the fleet backup story in one place (palimpsest#60). A fixed-layout
    # topology of on-fleet git-annex replication (inkpotmonkey's ~/Pictures + rk1b's
    # music → kelpy, live/green) and restic off-site to rsync.net (disabled/grey today),
    # plus the git-annex inventory ACROSS HOSTS AND USERS (git_annex_repo_info + health
    # gauges) and the off-site status table (backup_restic_enabled, off ≠ missing).
    ln -s ${./dashboards/backups.json} $out/backups.json
    # Hardware Health: the physical layer beneath the OS — temperature, thermal
    # throttling, fans and derived power across the BARE-METAL fleet (kelpy is a
    # container with no hwmon/thermal/cooling devices and is deliberately absent).
    # Forensic by design — cross-host comparison on a shared crosshair to answer "was
    # that slowdown thermal?" — with a preventative glance row on top. Throttle state
    # (node_cooling_device_cur_state) is the fleet-comparable verdict; absolute temps
    # are not, so temperature panels carry no threshold bands. Disk/SSD wear is absent
    # and tracked as palimpsest#162. Graduated from map #30's fog (#160).
    ln -s ${./dashboards/hardware-health.json} $out/hardware-health.json
    # Watchers: is the watching machinery itself still running? Every other board asks
    # whether the WATCHED thing is healthy; this one ranks the curated watcher timers by
    # OVERDUE FACTOR (time since last trigger / the tier's expected cadence) so a 60s and
    # a daily watcher compare directly, cross-checks the three that publish their own run
    # timestamp, and carries the book-filer stuck-file metrics. Not an alert console —
    # the stack is collection-only, so no metric records that an alert fired (#161).
    ln -s ${./dashboards/watchers.json} $out/watchers.json
    # DNS Resolvers: the fleet's two blocky resolvers (kelpy, rk1b) compared against each
    # other. Organised around TWIN AGREEMENT — ADR-0023's tailscale setup queries both
    # nameservers in PARALLEL and takes the quickest answer, so both see the same traffic
    # and run the same config, which makes divergence between them the signal and absolute
    # query rate nearly meaningless as health. Glance (answering/armed/erroring/slowest),
    # twin divergence (upstream split, upstream p50-p95 latency, error share), traffic &
    # cache (hit ratio, response types, per-client table), and denylist freshness + fault
    # counters. Latency carries NO threshold bands: the house band (1s/3s) is 100-1000x
    # above this fleet's single-digit-millisecond p95, so the comparison is the verdict.
    # Consumes the blocky_* scrape job from #39, previously collected and unused (#164).
    ln -s ${./dashboards/dns-resolvers.json} $out/dns-resolvers.json
  '';

  # "Advanced" folder: deep-dive boards kept available but off the primary nav. The
  # imported Node Exporter Full board (grafana.com 1860) — the ~200-panel firehose used
  # for the rare deep dive that the curated Host Drill-Down doesn't cover. Provisioned
  # into its own Grafana folder so it no longer competes with the in-house boards (#35).
  advancedDashboardsDir = pkgs.runCommand "grafana-dashboards-advanced" { } ''
    mkdir -p $out
    ln -s ${dashboards.node-exporter} $out/node-exporter.json
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
                static_configs = makeTargets config.services.prometheus.exporters.node.port allNodes;
              }
              # blocky has always exposed the full `blocky_*` series (queries, cache
              # hit/miss, block counts, upstream resolver timings) on its HTTP port; until
              # this job nothing collected them. It is the only self-hosted app on the
              # fleet already emitting app-level metrics.
              #
              # EVERY declared resolver is scraped, not just this host's own blocky: fleet
              # DNS is deliberately dual (ADR-0023), so "one resolver is degraded" and "DNS
              # is down" are different incidents and only a per-resolver series separates
              # them. Hence MagicDNS names rather than the 127.0.0.1 a local-only job would
              # use — `instance` then carries the host name the boards rewrite into `host`,
              # where a loopback target would flatten both resolvers onto one nameless
              # series. The remote scrape reaches blocky over the tailnet, which is what
              # blocky.nix's tailscale0 firewall opening is for.
              #
              # Unconditional, unlike the dmarc/gatus jobs below: those scrape a co-located
              # loopback exporter and so must be gated on the profile that provides it,
              # whereas these targets are remote — the monitoring host need not run blocky.
              {
                job_name = "blocky";
                static_configs = makeTargets settings.dns.httpPort settings.dns.nameserverHosts;
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
            {
              name = "Advanced";
              # Land 1860 in its own Grafana folder so it's tucked away from the main nav.
              folder = "Advanced";
              options.path = advancedDashboardsDir;
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
