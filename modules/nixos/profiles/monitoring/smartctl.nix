{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-smartctl;
in
{
  options.custom.profiles.monitoring-smartctl = {
    enable = lib.mkEnableOption "smartctl exporter configuration";
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.smartctl = {
      enable = true;
      listenAddress = "0.0.0.0";
    };

    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
      config.services.prometheus.exporters.smartctl.port
    ];
  };
}
