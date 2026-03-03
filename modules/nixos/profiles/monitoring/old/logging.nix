{
  lib,
  ...
}:
{
  # VictoriaLogs
  services.victorialogs = {
    enable = true;
  };
  systemd.services.victorialogs.serviceConfig.DynamicUser = lib.mkForce false;

  # Vector for log shipping
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
          .host = "nixos"
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
        endpoint = "http://localhost:9428/insert";
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

  systemd.services.vector.serviceConfig.DynamicUser = lib.mkForce false;

  # System users for logging services
  # System users for logging services
  users = {
    users = {
      victorialogs = {
        isSystemUser = true;
        group = "users";
      };
      vector = {
        isSystemUser = true;
        group = "vector";
        extraGroups = [ "systemd-journal" ];
      };
    };
    groups.vector = { };
  };

  environment.persistence."/persistent".directories = [
    {
      directory = "/var/lib/victorialogs";
      user = "victorialogs";
      group = "users";
      mode = "0700";
    }
    {
      directory = "/var/lib/vector";
      user = "vector";
      group = "vector";
      mode = "0700";
    }
  ];
}
