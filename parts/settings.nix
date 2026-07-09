{ inputs, self, ... }:
let
  # Load node metadata from secrets/nodes.nix. getSecretPath returns the real file when
  # the secrets input provides it, else a mock (and warns) so the flake still evaluates
  # standalone — see lib/default.nix and docs/adr/0012. The mock has no node keys, so
  # every lookup below cleanly falls through to its placeholder.
  secretsNodes = import (self.lib.getSecretPath "nodes.nix");

  # Look up node metadata (tailscale/public IPs), falling back to a placeholder when an
  # entry is absent. The fallback is LOUD (mirrors lib's warnMock): a placeholder IP
  # silently reaching DNS/blocky during a real build would be a hard-to-spot mistake.
  getMeta =
    nodeName: path: default:
    let
      attrPath = [ nodeName ] ++ path;
      found = lib.attrByPath attrPath null secretsNodes;
    in
    if found != null then
      found
    else
      lib.warn "settings: node metadata '${lib.concatStringsSep "." attrPath}' missing from secrets/nodes.nix — using placeholder ${builtins.toJSON default}." default;

  inherit (inputs.nixpkgs) lib;
  primaryDomain = "palebluebytes.space";

  # The service registry. Each entry: `edge` (host where DNS points + Caddy runs),
  # `port`, optional `origin` (host actually running it when off-edge), optional
  # `proxy = false` (bypass Caddy). Optional `monitor` controls the ADR-0019 uptime
  # watcher (monitor-by-default): `monitor.enable` (default true) and, when you set
  # it false, a required `monitor.reason`. Opting out here exempts a SERVED service
  # from probing/alerting; it does not stop Caddy fronting it (to fully retire a
  # service, remove its entry). The slice-04 flake-check guard enforces both the
  # reason-when-disabled rule and that every monitored service has a buildable probe.
  services = {
    public = {
      matrix = {
        edge = "kelpy";
        port = 6167;
        proxy = false;
      };
      mail = {
        edge = "kelpy";
        port = 8082;
        proxy = false;
      };
      # matrix-hookshot's public webhook/OAuth listener. Caddy auto-fronts it
      # (proxy omitted → vhost created, DNS grey-clouded) so GitHub and generic
      # webhooks can POST in. The appservice port (loopback) is internal, kept in
      # the hookshot module. See modules/nixos/profiles/matrix/hookshot.nix.
      hookshot = {
        edge = "kelpy";
        port = 9000;
      };
      jellyfin = {
        edge = "kelpy";
        port = 8096;
      };
    };
    private = {
      litellm = {
        edge = "kelpy";
        port = 4000;
      };
      monitoring = {
        edge = "kelpy";
        port = 3001;
        origin = "rk1b";
      };
      paperless = {
        edge = "kelpy";
        port = 28981;
      };
      torrent = {
        edge = "kelpy";
        port = 8080;
      };
      # affine is disabled for now (custom.profiles.affine.enable = false, so no
      # backend) — keep it out of the registry so Caddy doesn't front a dead vhost
      # and the uptime watcher doesn't probe/alert on it. Re-add when re-enabled.
      # affine = {
      #   edge = "kelpy";
      #   port = 3010;
      # };
      openclaw = {
        edge = "kelpy";
        port = 8001;
      };
      # Home Assistant. It RUNS on rk1b, but is fronted by kelpy's Caddy (TLS via
      # Cloudflare DNS-01 + the internal_only tailnet guard). `edge` is the edge
      # (kelpy: where DNS points and Caddy runs); `origin` is the upstream Caddy
      # reverse-proxies to over tailscale. Reachable tailnet-only at home.<domain>.
      home = {
        edge = "kelpy";
        port = 8123;
        origin = "rk1b";
      };
      # Local llama.cpp endpoint on Turing Pi RK1 node rk1a. (rk1b was repurposed as the
      # Home Assistant voice node and no longer serves an LLM, so there is no localLlmB.)
      localLlmA = {
        edge = "rk1a";
        port = 8080;
      };
    };
  };

  # Collision check keys on the host that actually LISTENS on the port — the
  # origin when the service runs off-edge (e.g. Home Assistant on rk1b),
  # otherwise the edge it is co-located with.
  listenerHost = svc: svc.origin or svc.edge;
  allServiceEndpoints =
    (lib.mapAttrsToList (_: svc: "${listenerHost svc}:${toString svc.port}") services.public)
    ++ (lib.mapAttrsToList (_: svc: "${listenerHost svc}:${toString svc.port}") services.private);

  uniqueEndpoints = lib.unique allServiceEndpoints;

  checkPorts =
    if builtins.length uniqueEndpoints != builtins.length allServiceEndpoints then
      builtins.throw "Duplicate ports found on the same listener host in settings.nix! Endpoints: ${builtins.toJSON allServiceEndpoints}"
    else
      services;
in
{
  flake.settings = {
    admin.email = "admin@${primaryDomain}";
    inherit primaryDomain;
    mailDomain = primaryDomain;

    # Mail domains served by Stalwart — the single source of truth consumed by both the
    # kelpy mail profile and the `dns` app (which generates the per-domain mail records).
    mail = {
      domain = primaryDomain;
      extraDomains = [ "palebluebytes.xyz" ];
    };

    # The tailnet's fleet DNS resolvers: the hosts running blocky that are registered
    # as tailscale global nameservers (ADR-0023). Single source of truth for the
    # `tailscale-dns` app, which resolves each host's CURRENT tailscale IP and pushes
    # the admin-console nameserver list — self-healing against the reflash IP-drift
    # that silently killed the old porcupineFish secondary. Keep in sync with the
    # `custom.profiles.blocky.enable` grants in hosts/default.nix.
    dns.nameserverHosts = [
      "kelpy"
      "rk1b"
    ];

    nodes.kelpy = {
      hostName = "kelpy";
      domain = "palebluebytes.space";
      tailscale = {
        ip4 = getMeta "kelpy" [ "tailscale" "ip4" ] "100.64.0.1";
        ip6 = getMeta "kelpy" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::1";
      };
      public = {
        ip4 = getMeta "kelpy" [ "public" "ip4" ] "0.0.0.0";
        ip6 = getMeta "kelpy" [ "public" "ip6" ] "::1";
      };
    };

    nodes.porcupineFish = {
      hostName = "porcupineFish";
      tailscale = {
        ip4 = getMeta "porcupineFish" [ "tailscale" "ip4" ] "100.64.0.2";
        ip6 = getMeta "porcupineFish" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::2";
      };
    };

    nodes.stargazer = {
      hostName = "stargazer";
      tailscale = {
        ip4 = getMeta "stargazer" [ "tailscale" "ip4" ] "100.64.0.3";
        ip6 = getMeta "stargazer" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::3";
      };
    };

    nodes.sawtoothShark = {
      hostName = "sawtoothShark";
    };

    nodes.potbelliedSeahorse = {
      hostName = "potbelliedSeahorse";
    };

    nodes.rk1a = {
      hostName = "rk1a";
      tailscale = {
        ip4 = getMeta "rk1a" [ "tailscale" "ip4" ] "100.64.0.4";
        ip6 = getMeta "rk1a" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::4";
      };
    };

    nodes.rk1b = {
      hostName = "rk1b";
      tailscale = {
        ip4 = getMeta "rk1b" [ "tailscale" "ip4" ] "100.64.0.5";
        ip6 = getMeta "rk1b" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::5";
      };
    };

    services = checkPorts;

    # Hosts that run the Caddy edge profile (proxy.nix). The ADR-0019 uptime
    # watcher probes a service's HTTPS vhost through Caddy when its edge is listed
    # here, else falls back to a raw TCP probe to the listener; the slice-04 guard
    # uses the same notion to decide whether a monitored service is probeable.
    # Extend when a second host runs the edge.
    caddyEdges = [ "kelpy" ];
  };
}
