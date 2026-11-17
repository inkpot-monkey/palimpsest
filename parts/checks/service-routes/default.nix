# property#10 item 3 — one reading of the service registry, not five.
#
# An entry in `settings.services.*` declares EITHER a single `port` or, when it is a
# path-routed vhost (`paths`, property#8), an attrset of prefix → port. Before this check
# the difference was decided independently in FIVE places — `proxy.nix`'s vhost generator,
# `parts/settings.nix`'s port-collision guard, `monitoring/watcher.nix`'s probe builder, and
# the uptime and boards-vhost checks — and nothing made them agree. The review that raised
# this found four; the fifth turned up on the way.
#
# The uptime check was the worst of them: it carried its own `listenerHost`, so a guard
# could have passed a registry the watcher then read differently.
#
# The sharp end is not "a third shape costs a sixth edit". It is that a MALFORMED entry
# today behaves DIFFERENTLY in each consumer rather than failing: an entry with both `port`
# and `paths` gets its ports counted by the collision guard, routed by prefix in Caddy, and
# probed twice — and one with neither silently contributes nothing anywhere. Either is a
# vhost that serves the wrong thing with every check green.
#
# So this asserts the shared accessor against synthetic registries, malformed ones included,
# rather than against the real one: a green check then means the logic is right, not that the
# current registry happens not to trip it.
{ pkgs, self, ... }:
let
  inherit (pkgs) lib;
  r = self.lib.serviceRoutes;

  # --- fixtures -----------------------------------------------------------------
  singlePort = {
    edge = "kelpy";
    port = 4533;
  };
  offEdge = {
    edge = "kelpy";
    origin = "rk1b";
    port = 8096;
  };
  pathRouted = {
    edge = "kelpy";
    origin = "rk1b";
    paths = {
      "/property" = 9120;
      "/holds" = 9121;
    };
  };
  bothShapes = {
    edge = "kelpy";
    port = 1;
    paths = {
      "/x" = 2;
    };
  };
  neitherShape = {
    edge = "kelpy";
  };

  cases = [
    {
      name = "a single-port entry yields its one listener";
      actual = r.portsOf singlePort;
      expected = [ 4533 ];
    }
    {
      name = "a path-routed entry yields every backend port";
      actual = lib.sort (a: b: a < b) (r.portsOf pathRouted);
      expected = [
        9120
        9121
      ];
    }
    {
      name = "a path-routed entry has one route per prefix, in a stable order";
      actual = r.routesOf pathRouted;
      expected = [
        {
          prefix = "/holds";
          port = 9121;
        }
        {
          prefix = "/property";
          port = 9120;
        }
      ];
    }
    {
      name = "the listening host is the origin when off-edge, else the edge";
      actual = [
        (r.listenerHost singlePort)
        (r.listenerHost offEdge)
      ];
      expected = [
        "kelpy"
        "rk1b"
      ];
    }
    {
      name = "a path-routed entry is recognised as such";
      actual = [
        (r.isPathRouted singlePort)
        (r.isPathRouted pathRouted)
      ];
      expected = [
        false
        true
      ];
    }
    # The two that matter. Each of these used to be accepted, differently, by each
    # consumer; the accessor is the one place that can refuse them.
    {
      name = "an entry declaring BOTH port and paths is a named violation";
      actual = r.shapeViolations { both = bothShapes; };
      expected = [ "both: declares both `port` and `paths`; an entry is one shape or the other" ];
    }
    {
      name = "an entry declaring NEITHER is a named violation";
      actual = r.shapeViolations { empty = neitherShape; };
      expected = [ "empty: declares neither `port` nor `paths`, so it has no listener" ];
    }
    {
      name = "well-formed entries produce no violations";
      actual = r.shapeViolations {
        inherit singlePort offEdge pathRouted;
      };
      expected = [ ];
    }
    # NO live-registry case here, deliberately. Reading `self.settings.services` forces
    # settings.nix's own `shapeViolations` throw, which fires FIRST — so such a case could
    # never report a failure, only crash with a different message and look like this check
    # was broken. The live registry is guarded at eval time by settings.nix, which is
    # stronger than a check anyone can forget to run; what is left for here is the logic.
  ];

  failures = lib.filter (c: c.actual != c.expected) cases;
  report = lib.concatMapStringsSep "\n" (
    c:
    "  ✗ ${c.name}\n      expected: ${builtins.toJSON c.expected}\n      actual:   ${builtins.toJSON c.actual}"
  ) failures;
in
pkgs.runCommand "check-service-routes"
  {
    passAsFile = [ "report" ];
    inherit report;
  }
  ''
    if [ -s "$reportPath" ]; then
      echo "service-routes: ${toString (builtins.length failures)} case(s) failed:" >&2
      cat "$reportPath" >&2
      exit 1
    fi
    echo "service-routes: all ${toString (builtins.length cases)} cases hold" > "$out"
  ''
