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
    # `levelFromMessage` / `demoteToDebug` — declared next door so a service profile can set
    # them by importing that file, without dragging Vector in. See its header.
    ./log-levels.nix
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
          ''
          # Promote the severity a service writes into its own message text, then demote the
          # lines a service calls errors that this fleet has decided are not. The journald
          # source can only report PRIORITY, and a service logging to stdout is PRIORITY=6
          # for every line — so without the first half its errors arrive labelled `info` and
          # the fleet's error views cannot see them at all. See `levelFromMessage` and
          # `demoteToDebug` above for the measurements, and for what deliberately stays
          # unmatched.
          + lib.optionalString (cfg.levelFromMessage != { }) ''

            # Whatever a service calls its levels, mapped onto the five the dashboards and
            # the PRIORITY table above use. Every promotion goes through this, so an
            # unrecognised token leaves `level` ALONE rather than inventing a new label
            # value — postgres says LOG and NOTICE, blocky can say WARN, go services say
            # FATAL, and a dashboard filtering `level:in(error,critical,fatal)` must not
            # have to know that.
            level_names = {
              "trace": "debug",
              "debug": "debug",
              "info": "info",
              "notice": "info",
              "log": "info",
              "warn": "warning",
              "warning": "warning",
              "err": "error",
              "error": "error",
              "crit": "critical",
              "critical": "critical",
              "alert": "critical",
              "fatal": "fatal",
              "panic": "fatal",
              "emerg": "fatal"
            }
          ''
          + lib.concatStrings (
            lib.mapAttrsToList (unit: pattern: ''

              if .unit == ${builtins.toJSON unit} {
                matched = parse_regex(to_string(._msg) ?? "", r'${pattern}') ?? null
                if matched != null {
                  # No `??` on to_string: it is infallible for a capture group, and VRL
                  # REFUSES an unnecessary error-coalesce (E651) rather than ignoring it.
                  mapped = get(level_names, [downcase(to_string(matched.lvl))]) ?? null
                  if mapped != null {
                    .level = mapped
                  }
                }
              }
            '') cfg.levelFromMessage
          )
          # LAST, so a demotion always beats the promotion above: a service that logs a
          # known-benign condition at ERROR gets promoted by its own format pattern and then
          # put back down, which is the correct order — the journal keeps what the service
          # said, and the error views keep their meaning.
          + lib.concatStrings (
            lib.mapAttrsToList (unit: needles: ''

              if .unit == ${builtins.toJSON unit} {
                demote_msg = to_string(._msg) ?? ""
                if ${lib.concatMapStringsSep " || " (n: "contains(demote_msg, ${builtins.toJSON n})") needles} {
                  .level = "debug"
                }
              }
            '') cfg.demoteToDebug
          );
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
          # Vector 0.57+ rejects fully-dynamic label templates (no static prefix) at startup
          # unless this opt-out is set, guarding against label-cardinality/injection from
          # untrusted event fields. Here every label comes from our own parse_journal transform
          # (hostname, systemd unit, job, derived level) — trusted internal values — and a static
          # prefix would corrupt the label values dashboards/queries expect verbatim. So opt out
          # explicitly. Fleet-uniform: the field landed in 0.57, and porcupineFish (whose
          # nixos-raspberrypi nixpkgs otherwise lags at 0.52) pins Vector to the fleet 0.57 in its
          # host config precisely so this shared sink config validates everywhere without gating.
          dangerously_allow_unconfined_template_resolution = true;
        };
      };
    };
  };
}
