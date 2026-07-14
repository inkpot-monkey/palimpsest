{
  config,
  lib,
  settings,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.proxy;
  inherit (settings.admin) email;
in
{
  options.custom.profiles.proxy = {
    enable = lib.mkEnableOption "Caddy reverse proxy configuration";
  };

  config = lib.mkIf cfg.enable {
    sops = {
      secrets.cloudflare_dns_token = {
        sopsFile = self.lib.getSecretPath "profiles/networking.yaml";
        owner = "caddy";
        group = "caddy";
      };
      templates.caddy_env = {
        content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder.cloudflare_dns_token}";
        owner = "caddy";
        group = "caddy";
      };
    };

    services.caddy = {
      enable = true;
      inherit email;
      package = pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/cloudflare@v0.2.1" ];
        hash = "sha256-pNIRthmPf+J6BPfJ51afBCWt66evnRs1+f9wv09EvK0=";
      };
      globalConfig = "";
      extraConfig = ''
        (internal_only) {
          @not_internal {
            not remote_ip 100.64.0.0/10 127.0.0.1 ::1 fd7a:115c:a1e0::/48
          }
          abort @not_internal
        }

        (cloudflare_tls) {
          tls {
            dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          }
        }
      '';
      environmentFile = config.sops.templates.caddy_env.path;

      virtualHosts =
        let
          allServices =
            (lib.mapAttrs (_: svc: svc // { isPublic = true; }) settings.services.public)
            // (lib.mapAttrs (_: svc: svc // { isPublic = false; }) settings.services.private);
          hostServices = lib.filterAttrs (
            _: svc: svc.edge == config.networking.hostName && (svc.proxy or true)
          ) allServices;
        in
        # NOTE: the apex (${domain}) is intentionally NOT served here — it resolves to a
        # Cloudflare Worker (see the apex ALIAS in parts/apps/dns/dnsconfig.ts), so apex
        # traffic never reaches Caddy.
        lib.mapAttrs' (
          name: svc:
          let
            # Most services are co-located with Caddy (proxy to loopback). A service may
            # instead run on another node and set `origin`, in which case Caddy proxies
            # to that node over tailscale by MagicDNS name (resolved live, not a pinned IP;
            # e.g. Home Assistant on rk1a). DNS still points at this (edge) host, so the
            # service stays tailnet-only behind internal_only.
            upstream = if svc ? origin then "${svc.origin}.${settings.tailnet}" else "127.0.0.1";
          in
          lib.nameValuePair "${name}.${config.networking.domain}" {
            extraConfig = ''
              ${lib.optionalString (!svc.isPublic) "import internal_only"}
              import cloudflare_tls
              handle {
                reverse_proxy ${upstream}:${toString svc.port}
              }
            '';
          }
        ) hostServices;
    };

    # Open firewall ports
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        config.services.caddy.dataDir
      ];
    };
  };
}
