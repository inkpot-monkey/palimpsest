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
        hash = "sha256-jNV5COlQTKSJJk8gUZ3KEs8SGC8Z7Aiy5fk7/DvkXIo=";
      };
      globalConfig = "";
      extraConfig = ''
        # ── THE TAILNET GUARD ─────────────────────────────────────────────────────────
        # Every private service's only access control. 80/443 are open on ALL interfaces
        # (below), because the public services need them — so this matcher, not the
        # firewall, is what keeps forge, vault, photos and the rest off the internet.
        #
        # ⚠ THE ABORT MUST BE INSIDE A `handle`, AND THAT IS NOT A STYLE CHOICE. It was a
        # bare `abort @not_internal` until 2026-10-06 and did nothing whatsoever:
        # `handle` sorts AHEAD of `abort` in Caddy's directive order, and each vhost's own
        # `handle { reverse_proxy … }` carries no matcher — so it matched every request and
        # terminated the route chain before the abort was ever reached. Measured with
        # `caddy adapt` on both forms:
        #
        #   bare abort:        route[0] subroute        match=ALL          ← reverse_proxy
        #                      route[1] static_response match=not remote…  ← dead code
        #   abort in a handle: route[0] subroute        match=not remote_ip
        #                      route[1] subroute        match=ALL
        #
        # Confirmed live before the fix: a request from a PUBLIC source address to
        # vault/forge/library/photos (right Host + SNI, against kelpy's public IP) was
        # served 200. What had been protecting them was obscurity alone — a private
        # service's published A record is kelpy's TAILSCALE address (parts/apps/dns), so
        # the names do not resolve usefully from the internet. That is not a gate, and it
        # stops being even obscurity for anyone who can guess a subdomain.
        #
        # Two `handle` blocks are mutually exclusive and keep their written order, so the
        # guarded one has to be imported BEFORE the vhost's own handle. It is: the import
        # sits at the top of every private vhost's extraConfig below.
        (internal_only) {
          @not_internal {
            not remote_ip 100.64.0.0/10 127.0.0.1 ::1 fd7a:115c:a1e0::/48
          }
          handle @not_internal {
            abort
          }
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
