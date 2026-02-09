{ config, lib, ... }:
let
  network = "mesh";
  owner = "nebula-${network}";
  name = config.networking.hostName;
in
{
  # In your sops configuration
  sops.secrets = {
    "nebula/ca/crt" = { inherit owner; };
    "nebula/${name}/crt" = { inherit owner; };
    "nebula/${name}/key" = {
      inherit owner;
      mode = "0400";
    };
  };

  services.nebula.networks.${network} = {
    enable = true;
    ca = config.sops.secrets."nebula/ca/crt".path;
    cert = config.sops.secrets."nebula/${name}/crt".path;
    key = config.sops.secrets."nebula/${name}/key".path;
    lighthouses = lib.mkDefault [ "192.168.100.1" ];
    staticHostMap = {
      "192.168.100.1" = [ "lighthouse.palebluebytes.space:4242" ];
    };
    firewall = {
      outbound = [
        {
          host = "any";
          port = "any";
          proto = "any";
        }
      ];
      inbound = [
        {
          host = "any";
          port = "any";
          proto = "any";
        }
      ];
    };
  };

  services.resolved = {
    enable = true;
    settings.Resolve.Domains = [ "~nebula" ];
    # TODO: services.resolved.extraConfig is deprecated. Fix nebula DNS config.
    # extraConfig = ''
    #   name_server=192.168.100.1#5353
    #   domain=nebula
    # '';
  };
}
