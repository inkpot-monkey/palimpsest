{
  config,
  ...
}:

{
  services.prometheus.exporters.smartctl = {
    enable = true;
    listenAddress = "0.0.0.0";
  };

  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    config.services.prometheus.exporters.smartctl.port
  ];
}
