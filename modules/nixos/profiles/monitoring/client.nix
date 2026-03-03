{
  config,
  settings,
  ...
}:

let
  receiver = settings.services.private.monitoring.node;
in
{
  imports = [
    ./exporters.nix
  ];

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    config.services.prometheus.exporters.node.port
    config.services.prometheus.exporters.systemd.port
    config.services.prometheus.exporters.smartctl.port
    config.services.prometheus.exporters.restic.port
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
      };
    };
  };
}
