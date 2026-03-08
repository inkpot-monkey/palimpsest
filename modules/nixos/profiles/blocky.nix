{
  config,
  options,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  inherit (lib) mkIf;
  hasTailscale = config.services.tailscale.enable;
in
{
  config = lib.mkMerge [
    {
      networking.nameservers = [ "127.0.0.1" ];

      services.blocky = {
        enable = true;
        # Use the unstable package to ensure we have the latest binary.
        package = inputs.nixpkgs.legacyPackages.${pkgs.system}.blocky;
        settings = {
          ports.dns = 53; # Port for incoming DNS Queries.

          bootstrapDns = {
            upstream = "https://one.one.one.one/dns-query";
            ips = [
              "1.1.1.1"
              "1.0.0.1"
              "9.9.9.9"
            ];
          };

          upstreams.groups.default = [
            "https://cloudflare-dns.com/dns-query"
            "https://dns.quad9.net/dns-query"
          ];

          caching = {
            minTime = "5m";
            maxTime = "30m";
            prefetching = true;
          };

          conditional.mapping = mkIf hasTailscale {
            "ts.net" = "100.100.100.100";
            "100.100.100.100.in-addr.arpa" = "100.100.100.100";
          };

          blocking = {
            denylists = {
              ads = [ "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ];
            };
            clientGroupsBlock = {
              default = [ "ads" ];
            };
          };

          prometheus.enable = true;
          ports.http = 4001;
        };
      };

      networking.firewall = {
        allowedTCPPorts = [ 4001 ];
      };

      networking.firewall.interfaces."tailscale0" = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 ];
      };
    }
    (lib.optionalAttrs (options.services.resolved ? settings) {
      services.resolved.settings.Resolve.DNSStubListener = "no";
    })
    (lib.optionalAttrs (!(options.services.resolved ? settings)) {
      services.resolved.extraConfig = ''
        DNSStubListener=no
      '';
    })
  ];
}
