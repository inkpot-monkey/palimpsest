# ADR-0026 slice 04 — the monitor-by-default guard.
#
# The uptime watcher derives its endpoints from settings.services, so a new
# service is monitored automatically. This `nix flake check` is the build-time net
# for the two ways that can still go wrong, turning each into a build error instead
# of a 3am false alert:
#   1. a service opts out of monitoring (monitor.enable = false) without a reason, and
#   2. a MONITORED service can't be given a buildable probe — its Caddy edge (HTTPS)
#      or its listener (TCP) has no tailscale IP for the watcher to target.
{ pkgs, self, ... }:
let
  inherit (pkgs) lib;
  inherit (self) settings;

  # The invariant checker, parameterised over (services, caddyEdges, nodes) so the
  # fixtures below can exercise it against synthetic registries — a green check then
  # means the logic works, not that it is vacuous. Returns a list of human-readable
  # violation strings (empty = all invariants hold).
  violations =
    {
      services,
      caddyEdges,
      nodes,
    }:
    let
      monitored = svc: svc.monitor.enable or true;
      listenerHost = svc: svc.origin or svc.edge;
      hasIp = host: (nodes.${host} or { }) ? tailscale && (nodes.${host}.tailscale ? ip4);
      # Which host the watcher would point the probe at: the edge for an HTTPS-via-Caddy
      # probe, else the listener for a raw TCP probe (mirrors watcher.nix).
      probeHost = svc: if lib.elem svc.edge caddyEdges then svc.edge else listenerHost svc;
    in
    lib.flatten (
      lib.mapAttrsToList (
        name: svc:
        (lib.optional (
          !(monitored svc) && (svc.monitor.reason or "") == ""
        ) "${name}: monitor.enable = false but no monitor.reason given")
        ++ (lib.optional (
          monitored svc && !(hasIp (probeHost svc))
        ) "${name}: monitored but ${probeHost svc} has no tailscale.ip4 (no buildable probe)")
      ) services
    );

  allServices = settings.services.public // settings.services.private;
  realViolations = violations {
    services = allServices;
    inherit (settings) caddyEdges nodes;
  };

  # Fixtures — prove the checker flags both failure shapes and passes a good opt-out.
  badOptOut = violations {
    services.foo = {
      edge = "kelpy";
      port = 1;
      monitor.enable = false;
    };
    caddyEdges = [ "kelpy" ];
    nodes.kelpy.tailscale.ip4 = "100.0.0.1";
  };
  badProbe = violations {
    services.bar = {
      edge = "ghost";
      port = 1;
    };
    caddyEdges = [ "kelpy" ];
    nodes = { };
  };
  goodOptOut = violations {
    services.foo = {
      edge = "kelpy";
      port = 1;
      monitor = {
        enable = false;
        reason = "served but intentionally exempt";
      };
    };
    caddyEdges = [ "kelpy" ];
    nodes.kelpy.tailscale.ip4 = "100.0.0.1";
  };

  selfTestOk = (lib.length badOptOut == 1) && (lib.length badProbe == 1) && (goodOptOut == [ ]);
in
assert lib.assertMsg selfTestOk
  "uptime-monitoring guard self-test failed (the invariant checker is broken)";
if realViolations != [ ] then
  throw ''
    uptime-monitoring guard (ADR-0026 slice 04) failed:
    ${lib.concatMapStringsSep "\n" (v: "  - " + v) realViolations}
  ''
else
  pkgs.runCommandLocal "uptime-monitoring-guard" { } ''
    echo "monitor-by-default invariants hold for ${toString (lib.length (lib.attrNames allServices))} services" > "$out"
  ''
