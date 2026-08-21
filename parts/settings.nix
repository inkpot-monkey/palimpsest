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
      # Home Assistant. It RUNS on rk1a (the voice node, ADR-0027), but is fronted by
      # kelpy's Caddy (TLS via Cloudflare DNS-01 + the internal_only tailnet guard).
      # `edge` is the edge (kelpy: where DNS points and Caddy runs); `origin` is the
      # upstream Caddy reverse-proxies to over tailscale. Reachable tailnet-only at
      # home.<domain>. Flip `origin` only after HA is verified up on the new node, so
      # Caddy never proxies to a dead upstream (ADR-0027 migration ordering).
      home = {
        edge = "kelpy";
        port = 8123;
        origin = "rk1a";
      };
      # Navidrome — the friends' shared music platform (ADR-0027). Same edge/origin
      # split as Home Assistant: it RUNS on rk1b (media node, library on the NVMe /var/cache),
      # fronted by kelpy's Caddy at music.<domain> with TLS + the internal_only tailnet
      # guard. The vhost subdomain is this attribute name, so it's `music` (not
      # `navidrome`); the profile that runs it is custom.profiles.navidrome.
      music = {
        edge = "kelpy";
        port = 4533;
        origin = "rk1b";
      };
      # Music Assistant — the library-plane brain + Party guest queue (ADR-0031). Same edge/origin
      # split as Navidrome: it RUNS on rk1b (media node), fronted by kelpy's Caddy at ma.<domain>
      # with TLS + the internal_only tailnet guard. This is the HOST's control UI (login the MA
      # admin `provisioner`); the Party *guest* QR uses MA's own access mechanism, not this vhost.
      # The profile that runs it is custom.profiles.music-assistant; port is MA's web/API port.
      ma = {
        edge = "kelpy";
        port = 8095;
        origin = "rk1b";
      };
      # Stump — the reading catalog over the git-annex document library (ADR-0031, #113).
      # Same edge/origin split as Navidrome: it RUNS on rk1b (media node, corpus on the NVMe
      # /var/cache/library), fronted by kelpy's Caddy at library.<domain> with TLS + the
      # internal_only tailnet guard. Deploy BOTH hosts or the tailnet gets a TLS error.
      #
      # This vhost is the BROWSE path. It was written as the Supernote's OPDS delivery path too
      # (#114), on the assumption the device could not join the tailnet — it can (ADR-0031,
      # revision 2026-08-17), so the device now pulls from rk1b DIRECTLY at
      # `http://rk1b.<tailnet>:10001/opds/v1.2/catalog`. Going through here would hairpin a book
      # stored on rk1b out to kelpy (a VPS) and back, gated by home upstream; measured, a 23MB
      # epub crawled. Both paths stay open and both are Basic-auth'd by Stump; see
      # docs/runbooks/supernote-koreader-opds.md.
      #
      # The vhost subdomain is this attribute name, so it's
      # `library`; the profile that runs it is custom.profiles.stump. Port is Stump's own default.
      library = {
        edge = "kelpy";
        port = 10001;
        origin = "rk1b";
      };
      # slskd — the Soulseek client that seeds the shared music library outward
      # (ADR-0028). It RUNS on kelpy (where the git-annex `music` replica lives),
      # inside the ProtonVPN container's netns, with its web UI published to loopback;
      # kelpy's Caddy fronts it tailnet-only at slskd.<domain> (internal_only guard).
      # No `origin`: unlike Navidrome it is co-located with the edge. The profile that
      # runs it is custom.profiles.media.slskd.
      slskd = {
        edge = "kelpy";
        port = 5030;
      };
    };
  };

  # Collision check keys on the host that actually LISTENS on the port — the
  # origin when the service runs off-edge (e.g. Home Assistant on rk1a),
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

    # The tailnet's MagicDNS suffix (tailscale-assigned, stable). Every fleet host is
    # reachable at `<hostName>.${tailnet}`, resolved live by blocky's ts.net forward
    # (ADR-0021/0023). Monitoring scrape targets, Gatus raw-TCP probes, and Caddy
    # upstreams use these NAMES instead of pinned tailscale IPs — which silently rot
    # when a host re-keys (the porcupineFish scrape breakage). Only consumers that
    # structurally need an IP literal (HA trusted_proxies) and the deliberately-pinned
    # Vector receiver (ADR-0022) still read nodes.*.tailscale.ip4.
    tailnet = "tail8596c.ts.net";

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

    # blocky's HTTP port: its API and, since `prometheus.enable` is on, its `/metrics`
    # endpoint (blocky.nix). Declared here rather than in the profile because the
    # monitoring server scrapes resolvers it does not itself build (server.nix), so it
    # has no config to read the port back off.
    dns.httpPort = 4001;

    # `presence` is a host's operational cadence (CONTEXT.md → Always-on / On-demand
    # host): `always-on` runs 24/7, `on-demand` runs only when in use. It is plumbed
    # into the node scrape targets as a label (server.nix) so a host's monitoring
    # alert-worthiness is *derived* — an on-demand host being unreachable is expected,
    # never a fault, so it never colours a fleet health signal red.
    #
    # `onTailnet` is the separate question of whether the node is REGISTERED on the
    # tailnet and so has a MagicDNS name (`<hostName>.${tailnet}`) at all. Defaults to
    # true — nearly every node is — and only a node running no tailscale sets it false.
    # It is not a monitoring policy either: the `node` scrape job addresses targets BY
    # MagicDNS name (server.nix), so a node without one is not an unreachable target but
    # an *unresolvable* one. MagicDNS SERVFAILs a name it does not own and blocky's
    # conditional upstream has nothing to fall back to, so every such scrape is counted
    # as a resolver error — silently, since blocky does not log an upstream SERVFAIL
    # (palimpsest#165, where one undeclared node produced ~16% of rk1b's query errors).
    # Do NOT conflate it with `presence`: an on-demand host that is merely powered off
    # still HAS a MagicDNS name, still resolves, and is *meant* to read `up == 0`
    # (ADR-0026). The value is tied back to each host's real `services.tailscale.enable`
    # by the host_fleet_coherence check, so it cannot drift from the machine it describes.
    nodes.kelpy = {
      hostName = "kelpy";
      domain = "palebluebytes.space";
      presence = "always-on";
      tailscale = {
        ip4 = getMeta "kelpy" [ "tailscale" "ip4" ] "100.64.0.1";
        ip6 = getMeta "kelpy" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::1";
      };
      public = {
        ip4 = getMeta "kelpy" [ "public" "ip4" ] "0.0.0.0";
        ip6 = getMeta "kelpy" [ "public" "ip6" ] "::1";
      };
    };

    # These hosts are scrape targets by MagicDNS name (server.nix makeTargets) and Gatus
    # probe targets by name — neither needs a pinned tailscale IP. Only kelpy (HA
    # trusted_proxies + Caddy edge) and rk1b (Vector receiver, ADR-0022) keep a
    # `tailscale` block, for the consumers that structurally need an IP literal.
    nodes.porcupineFish = {
      hostName = "porcupineFish";
      presence = "always-on";
    };

    nodes.stargazer = {
      hostName = "stargazer";
      presence = "on-demand";
    };

    nodes.sawtoothShark = {
      hostName = "sawtoothShark";
      presence = "on-demand";
    };

    nodes.weedySeadragon = {
      hostName = "weedySeadragon";
      presence = "on-demand";
    };

    nodes.potbelliedSeahorse = {
      hostName = "potbelliedSeahorse";
      presence = "on-demand";
      # A nebula lighthouse, not a tailscale node — hosts/potbelliedSeahorse/configuration.nix
      # enables `nebula` and never `tailscale`, so there is no `<host>.<tailnet>` name for
      # anything to resolve. The only node on the fleet for which this is true.
      onTailnet = false;
    };

    nodes.rk1a = {
      hostName = "rk1a";
      presence = "always-on";
    };

    nodes.rk1b = {
      hostName = "rk1b";
      presence = "always-on";
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
