{
  config,
  options,
  lib,
  pkgs,
  inputs,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.blocky;
  hasTailscale = config.services.tailscale.enable;
  domain = settings.nodes.kelpy.domain;

  allServices =
    (lib.mapAttrs (_: svc: svc // { isPublic = true; }) settings.services.public)
    // (lib.mapAttrs (_: svc: svc // { isPublic = false; }) settings.services.private);

  # DNS names are case-insensitive; store them lowercased so camelCase service keys
  # (e.g. localLlmA) match — blocky lowercases queries but matches hosts-file/customDNS
  # entries verbatim.
  fqdn = name: lib.toLower "${name}.${domain}";

  # Public services resolve to a node's stable public IP — safe to hardcode in customDNS.
  publicMapping = lib.mapAttrs' (
    name: svc: lib.nameValuePair (fqdn name) settings.nodes.${svc.node}.public.ip4
  ) (lib.filterAttrs (_: svc: svc.isPublic) allServices);

  # Private services point at a node's TAILSCALE IP, which drifts whenever a node
  # re-registers (e.g. after a reflash). Instead of baking the (drift-prone) IPs from
  # secrets/nodes.nix into the config, resolve them at runtime from tailscale and feed
  # blocky via a generated hosts file (see the blocky-service-hosts unit below).
  tailscaleServices = lib.mapAttrsToList (name: svc: {
    host = fqdn name;
    inherit (svc) node;
  }) (lib.filterAttrs (_: svc: !svc.isPublic) allServices);

  # Deliberately NOT under /run/blocky: that's blocky's RuntimeDirectory, which systemd
  # wipes on every blocky restart — and the generator restarts blocky, so the file would
  # delete itself. Use a separate runtime dir.
  servicesHostsFile = "/run/blocky-services/tailscale-services.hosts";
in
{
  options.custom.profiles.blocky = {
    enable = lib.mkEnableOption "Blocky DNS server configuration";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        networking.nameservers = [ "127.0.0.1" ];

        services.blocky = {
          enable = true;
          # Use the unstable nixpkgs' blocky (0.30) on every host. The pinned pi toolchain's
          # nixpkgs ships an older 0.27 whose hostsFile handling differs (it doesn't serve
          # local hostsFile entries the same way), which would break the dynamic service
          # resolution below. Pulling it from inputs.nixpkgs keeps blocky consistent across
          # the fleet (kelpy already tracks unstable; this aligns the Pi).
          package = inputs.nixpkgs.legacyPackages.${config.nixpkgs.hostPlatform.system}.blocky;
          settings = {
            # Bind a wildcard rather than the host's (per-reflash, drift-prone) Tailscale
            # IP: that lets blocky bind immediately on boot — no stale-IP failure, no race
            # waiting for tailscaled to assign an address — and the firewall below restricts
            # external :53 to the tailscale0 interface, so exposure is unchanged.
            ports.dns = [ ":53" ];

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

            conditional.mapping = lib.mkIf hasTailscale {
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

            customDNS = {
              customTTL = "1h";
              mapping = publicMapping;
            };

            # Tailscale-targeted services come from a hosts file regenerated at runtime
            # with current IPs (blocky-service-hosts.service). The minimal `sources`-only
            # schema stays valid across blocky 0.27 (pi nixpkgs) and 0.30 (unstable).
            hostsFile.sources = lib.mkIf hasTailscale [ servicesHostsFile ];

            prometheus.enable = true;
            ports.http = 4001;
          };
        };

        # blocky's DNS (53) and HTTP API/metrics (4001) are only for the host itself and
        # tailnet clients. Scope BOTH to tailscale0 so neither is exposed on a public
        # interface (e.g. kelpy's WAN — a global allowedTCPPorts=[4001] made the blocky
        # API + /metrics reachable from the internet). Loopback is always allowed, so a
        # same-host prometheus still scrapes :4001 fine; remote scrapes go over tailscale.
        networking.firewall.interfaces."tailscale0" = {
          allowedTCPPorts = [
            53
            4001
          ];
          allowedUDPPorts = [ 53 ];
        };

        # Dynamic tailscale-service resolution (avoids hardcoded, drift-prone IPs).
        # Pre-create the file so blocky's hostsFile source always exists; the generator
        # populates it with current IPs and the timer refreshes it.
        systemd.tmpfiles.rules = lib.mkIf hasTailscale [
          "d /run/blocky-services 0755 root root -"
          "f ${servicesHostsFile} 0644 root root -"
        ];

        systemd.services.blocky-service-hosts = lib.mkIf hasTailscale {
          description = "Generate blocky hosts file for tailscale-targeted services (current IPs)";
          after = [
            "tailscaled.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          path = [
            pkgs.tailscale
            pkgs.coreutils
            config.systemd.package
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            set -uo pipefail
            install -d -m 0755 /run/blocky-services
            tmp="$(mktemp)"
            ${lib.concatMapStringsSep "\n" (s: ''
              ip="$(tailscale ip -4 ${lib.escapeShellArg s.node} 2>/dev/null | head -n1 || true)"
              [ -n "$ip" ] && printf '%s %s\n' "$ip" ${lib.escapeShellArg s.host} >> "$tmp"
            '') tailscaleServices}
            # Only swap + reload when the resolved IPs actually changed. blocky does NOT
            # hot-reload hostsFile (its /api/lists/refresh covers only block/allow lists),
            # so we restart it to pick up changes — a brief (~1s) blip that only happens
            # when a node's IP genuinely drifted, not on every periodic run.
            if ! cmp -s "$tmp" ${servicesHostsFile} 2>/dev/null; then
              install -m 0644 "$tmp" ${servicesHostsFile}
              if systemctl is-active --quiet blocky.service; then
                systemctl try-restart blocky.service
              fi
            fi
            rm -f "$tmp"
          '';
        };

        systemd.timers.blocky-service-hosts = lib.mkIf hasTailscale {
          description = "Refresh blocky tailscale-service IPs";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitActiveSec = "30min";
            Persistent = true;
          };
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
    ]
  );
}
