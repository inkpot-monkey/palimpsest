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

    levelFromMessage = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        {
          "home-assistant.service" =
            "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d+ (?P<lvl>WARNING|ERROR|CRITICAL) ";
        }
      '';
      description = ''
        Units whose own severity must be read out of the MESSAGE TEXT, keyed by unit name,
        each with the regex that finds it (one named capture group, `lvl`).

        WHY THIS EXISTS. `level` is derived from journald's `PRIORITY`, which is the only
        thing journald knows — and a service that writes to stdout gets PRIORITY=6 for every
        line it ever emits, errors included. Nothing is lost in the journal (the text still
        says `ERROR`), but every query, panel and alert that selects on `level` goes blind:
        the Logs dashboard's entire Errors/Warnings half is `level:in(error,…)`, so such a
        service contributes zero to it no matter how loudly it is failing. Measured on rk1a
        before this landed: 396 Home Assistant ERROR/WARNING lines in 24h, of which
        `level:in(error,warning,critical,fatal)` returned none.

        The fix has to be per-service because the FORMAT is per-service — only the service
        knows how it spells its own severity — so a service profile declares its own pattern
        here rather than this module guessing. Anchored patterns, so a line that merely
        mentions the word "error" is not promoted.

        ⚠ Write a pattern as an INDENTED (two single quotes) string, or double every
        backslash: a regular Nix string eats `\d` into a literal `d`, which then silently
        matches nothing.

        ⚠ Lines that do not match keep their journald level. For a Python service that means
        a traceback's continuation lines stay `info` while the `ERROR` line opening it is
        promoted. Deliberate: merging them needs a stateful `reduce` transform, which buffers
        each unit's last event until the next arrives and so makes the live tail lag — and
        this is the better count anyway, since a 20-line traceback is one error, not twenty.
      '';
    };
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
          # Promote the severity a service writes into its own message text. The journald
          # source can only report PRIORITY, and a service logging to stdout is PRIORITY=6
          # for every line — so without this its errors arrive labelled `info` and the
          # fleet's error views cannot see them at all. One anchored pattern per unit,
          # declared by the service's own profile; see `levelFromMessage` above for the
          # measurement that prompted it and for what deliberately stays unmatched.
          + lib.concatStrings (
            lib.mapAttrsToList (unit: pattern: ''

              if .unit == ${builtins.toJSON unit} {
                matched = parse_regex(to_string(._msg) ?? "", r'${pattern}') ?? null
                if matched != null {
                  # No `??` on to_string: it is infallible for a capture group, and VRL
                  # REFUSES an unnecessary error-coalesce (E651) rather than ignoring it.
                  found = downcase(to_string(matched.lvl))
                  # `warn` is what some loggers spell it; VictoriaLogs' Grafana plugin and
                  # every panel in logs.json expect `warning`, as the PRIORITY map above emits.
                  if found == "warn" {
                    found = "warning"
                  }
                  if found != "" {
                    .level = found
                  }
                }
              }
            '') cfg.levelFromMessage
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
