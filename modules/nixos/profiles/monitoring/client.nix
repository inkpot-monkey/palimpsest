{
  config,
  lib,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-client;
  # The host actually RUNNING the monitoring server — the origin when it lives
  # off-edge (server on rk1b, Caddy/DNS edge on kelpy), else the edge it shares
  # with Caddy. Mirrors settings.nix's `listenerHost` (svc.origin or svc.edge).
  receiver = settings.services.private.monitoring.origin or settings.services.private.monitoring.edge;
in
{
  imports = [
    ./exporters.nix
  ];

  options.custom.profiles.monitoring-client = {
    enable = lib.mkEnableOption "monitoring client (Vector, exporters) configuration";
  };

  config = lib.mkIf cfg.enable {
    custom.profiles.monitoring-exporters.enable = true;

    # Pin the monitoring receiver's tailscale IP so Vector can resolve it on nodes
    # without MagicDNS (e.g. rk1a). Without this, Vector throws "Name or service
    # not known" and all log delivery fails.
    networking.hosts = lib.optionalAttrs (
      settings.nodes ? ${receiver} && settings.nodes.${receiver} ? tailscale
    ) { "${settings.nodes.${receiver}.tailscale.ip4}" = [ receiver ]; };

    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
      config.services.prometheus.exporters.node.port
    ];

    services.vector = {
      enable = true;
      journaldAccess = true;
      settings = {
        sources.journald = {
          type = "journald";
        };

        transforms.parse_journal = {
          type = "remap";
          inputs = [ "journald" ];
          source = ''
            .job = "systemd-journal"
            .host = "${config.networking.hostName}"
            .unit = ._SYSTEMD_UNIT || .SYSLOG_IDENTIFIER || "unknown"

            # Map numeric priority to standard log level names
            # VictoriaLogs Grafana plugin expects: error, warn, info, debug
            level_map = {
              "0": "fatal",
              "1": "fatal",
              "2": "critical",
              "3": "error",
              "4": "warning",
              "5": "info",
              "6": "info",
              "7": "debug"
            }
            .level = get(level_map, [to_string!(.PRIORITY)]) ?? "info"
            ._msg = .message
            del(.message)
          ''
          # Demote systemd's benign BPF cgroup-attach failures to debug on CONTAINER hosts.
          # A container (kelpy is a vpsAdminOS/vpsFree container) shares the host kernel,
          # which owns cgroup BPF — so systemd PID 1 can't attach its per-unit BPF firewall/
          # device-control programs and logs an "error" every time a unit starts, e.g.
          #   "<unit>: bpf-firewall: Attaching egress BPF program to cgroup … failed: Invalid argument"
          #   "Attaching device control BPF program to cgroup … failed: Operation not permitted"
          # Non-fatal noise that otherwise dominates the error views. Keyed on the CAUSE
          # (boot.isContainer), not a hostname: covers any container host, and on a real
          # machine a BPF-attach failure stays an error (a genuinely new signal worth seeing).
          + lib.optionalString config.boot.isContainer ''
            msg = string(._msg) ?? ""
            if contains(msg, "BPF program to cgroup") {
              .level = "debug"
            }
          '';
        };

        sinks.victorialogs = {
          type = "loki";
          inputs = [ "parse_journal" ];
          endpoint = "http://${receiver}:9428/insert";
          encoding.codec = "json";
          labels = {
            job = "{{ job }}";
            host = "{{ host }}";
            unit = "{{ unit }}";
            level = "{{ level }}";
          };
          # Vector 0.49+ refuses fully-dynamic label templates (no static prefix)
          # unless this opt-out is set, to guard against label-cardinality/injection
          # from untrusted event fields. Here every label comes from our own
          # parse_journal transform (hostname, systemd unit, job, derived level) —
          # trusted internal values — and a static prefix would corrupt the label
          # values that dashboards/queries expect verbatim. So opt out explicitly.
          dangerously_allow_unconfined_template_resolution = true;
        };
      };
    };
  };
}
