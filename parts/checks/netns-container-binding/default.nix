# The shared-network-namespace binding guard.
#
# A container started with `--network=container:X` has no network stack of its own —
# it lives inside X's namespace. So when X restarts, podman tears that namespace down
# and builds a new one, and every container that joined it is left holding a destroyed
# netns: interfaces gone, routes gone, sockets bound to addresses that no longer exist.
# The joined container keeps running and systemd keeps reporting `active`, because its
# process never exits. It is simply, silently, off the network.
#
# `dependsOn` does NOT protect against this. It generates `Requires=` + `After=`, which
# only order startup — they do not propagate a restart. The wiring that does is
# `BindsTo=` (follow the peer's lifecycle) plus `PartOf=` (a restart of the peer restarts
# us), and it has to be added by hand.
#
# This bit on kelpy: gluetun's WireGuard tunnel collapsed, taking the netns default route
# with it, and qbittorrent-app and slskd sat `active (running)` for two days with no
# route to anywhere — qBittorrent's DHT flat at 0 nodes, torrents frozen in `metaDL`.
# Restarting gluetun alone would not have fixed them either, which is the other half of
# why this needs to be structural rather than a runbook step.
{ pkgs, self, ... }:
let
  inherit (pkgs) lib;

  # Parameterised over (containers, services) so the fixtures below can exercise it
  # against synthetic inputs — a green check then means the logic works, not that it
  # happened to find nothing. Returns human-readable violation strings ([] = holds).
  violations =
    { containers, services }:
    let
      # The peer whose namespace this container joins, if any. podman spells it
      # `--network=container:<name>`; anything else (bridge, host, none) is not our case.
      netnsPeer =
        container:
        lib.findFirst (peer: peer != null) null (
          map (
            opt:
            let
              m = builtins.match "--network=container:(.+)" opt;
            in
            if m == null then null else lib.head m
          ) (container.extraOptions or [ ])
        );
    in
    lib.flatten (
      lib.mapAttrsToList (
        name: container:
        let
          peer = netnsPeer container;
          unit = "podman-${name}";
          svc = services.${unit} or { };
          peerUnit = "podman-${peer}.service";
          has = field: lib.elem peerUnit (svc.${field} or [ ]);
        in
        lib.optionals (peer != null) (
          (lib.optional (!has "bindsTo")
            "${unit}: joins ${peer}'s network namespace but is missing BindsTo=${peerUnit} — a ${peer} restart would leave it attached to a destroyed netns, still `active` but off the network"
          )
          ++ (lib.optional (!has "partOf")
            "${unit}: joins ${peer}'s network namespace but is missing PartOf=${peerUnit} — restarting ${peer} would not restart it"
          )
        )
      ) containers
    );

  hostViolations = lib.mapAttrsToList (
    host: node:
    map (v: "${host}: ${v}") (violations {
      containers = node.config.virtualisation.oci-containers.containers or { };
      services = node.config.systemd.services or { };
    })
  ) self.nixosConfigurations;

  realViolations = lib.flatten hostViolations;

  # Fixtures — prove the checker flags the real shape and passes correct wiring.
  unbound = violations {
    containers.app.extraOptions = [ "--network=container:vpn" ];
    services = { };
  };
  boundProperly = violations {
    containers.app.extraOptions = [ "--network=container:vpn" ];
    services.podman-app = {
      bindsTo = [ "podman-vpn.service" ];
      partOf = [ "podman-vpn.service" ];
    };
  };
  # A container on its own bridge network is not in scope and must never be flagged.
  ownNetwork = violations {
    containers.app.extraOptions = [ "--network=bridge" ];
    services = { };
  };

  selfTestOk = (lib.length unbound == 2) && (boundProperly == [ ]) && (ownNetwork == [ ]);

  scanned = lib.length (lib.attrNames self.nixosConfigurations);
in
assert lib.assertMsg selfTestOk
  "netns-container-binding guard self-test failed (the invariant checker is broken)";
if realViolations != [ ] then
  throw ''
    netns-container-binding guard failed — container(s) share a network namespace
    without being bound to its owner's lifecycle:
    ${lib.concatMapStringsSep "\n" (v: "  - " + v) realViolations}

    Fix: on the joining container's unit, set
      bindsTo = [ "podman-<peer>.service" ];
      partOf  = [ "podman-<peer>.service" ];
  ''
else
  pkgs.runCommandLocal "netns-container-binding-guard" { } ''
    echo "shared-netns binding invariants hold across ${toString scanned} hosts" > "$out"
  ''
