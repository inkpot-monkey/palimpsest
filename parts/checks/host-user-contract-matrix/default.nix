# The host-side COHERENCE GATE (contract ADR-0004 Q5). The generic conformance matrix — synthetic
# users × host archetypes, proving the contract's invariants in isolation — now lives in
# the contract flake's own checks (`inputs.contract.checks.<system>.conformance`). What
# stays here is the fleet-specific tie-back: that THIS fleet's real hosts are coherent
# with the contract. Two light, real-host properties:
#   1. wherever the contract decides a display surface is needed (custom.gui.surface),
#      the host's display binding (gui.nix) actually renders it (sddm) — proof
#      the binding is wired fleet-wide, the host's half of the contract's gui decision;
#   2. every real host's exposed-trait is one the contract's archetypes cover, so
#      "the conformance suite passes" implies the real fleet's pairings are sound.
# Plus one property of the same shape but outside the contract — a DECLARATION that has
# to keep matching the machine it describes:
#   3. settings.nodes.<h>.onTailnet agrees with that host's real services.tailscale.enable.
{ self, pkgs, ... }:
let
  inherit (pkgs) lib;
  hosts = self.nixosConfigurations;

  # 1. The display binding renders the contract's gui decision on every real host.
  bindingWired =
    sys:
    let
      c = sys.config;
    in
    c.custom.gui.surface.enabled -> c.services.displayManager.sddm.enable;
  wiredResults = lib.mapAttrs (_: bindingWired) hosts;

  # 2. The real fleet's exposed-traits are covered by the contract's archetypes
  #    (the conformance suite builds both exposed=false and exposed=true archetypes).
  archetypeExposed = [
    false
    true
  ];
  realExposed = lib.unique (map (h: h.config.custom.host.exposed) (lib.attrValues hosts));
  exposedCovered = lib.all (e: lib.elem e archetypeExposed) realExposed;

  # 3. The `onTailnet` declaration matches the machine. The monitoring node job filters
  #    its scrape targets on this flag (monitoring/server.nix) but reads it from
  #    settings, NOT from the other hosts' configs: reaching across nixosConfigurations
  #    from inside a module would make every deploy evaluate the whole fleet. A check is
  #    the right place to pay that cost, and it is the only thing standing between the
  #    declaration and silent drift — palimpsest#165 WAS that drift, just undeclared.
  #    Nodes with no nixosConfiguration (phones, the e-reader) have no config to compare
  #    against and are skipped rather than assumed either way.
  declaredOnTailnet = name: self.settings.nodes.${name}.onTailnet or true;
  comparableNodes = lib.filter (name: hosts ? ${name}) (lib.attrNames self.settings.nodes);
  tailnetMismatches = lib.filter (
    name: declaredOnTailnet name != hosts.${name}.config.services.tailscale.enable
  ) comparableNodes;

  assertions = [
    {
      name = "coherence: the display binding renders the contract's gui decision on every real host";
      ok = lib.all (x: x) (lib.attrValues wiredResults);
    }
    {
      name = "coherence: every real host's exposed-trait is covered by a conformance archetype";
      ok = exposedCovered;
    }
    {
      name =
        "coherence: every node's onTailnet declaration matches its services.tailscale.enable"
        + lib.optionalString (
          tailnetMismatches != [ ]
        ) " — mismatched: ${lib.concatStringsSep ", " tailnetMismatches}";
      ok = tailnetMismatches == [ ];
    }
    {
      # Regression guard (cloud-review finding): the privileged-group clamp drops
      # operator-declared wheel unless granted, which once silently demoted this
      # break-glass recovery account. Its sudo is a critical safety net — assert it
      # survives, so the grant in hosts/default.nix can never be dropped unnoticed.
      name = "coherence: the weedySeadragon break-glass admin retains wheel (sudo)";
      ok = lib.elem "wheel" (hosts.weedySeadragon.config.users.users.admin.extraGroups or [ ]);
    }
  ];
  failures = builtins.filter (a: !a.ok) assertions;
  report = lib.concatMapStringsSep "\n" (
    a: "  ${if a.ok then "ok  " else "FAIL"}  ${a.name}"
  ) assertions;
in
pkgs.runCommand "host-fleet-coherence" { } ''
  cat <<'EOF'
  host↔contract coherence (real fleet ties back to the contract's conformance suite):
  ${report}
  EOF
  ${lib.optionalString (failures != [ ]) ''
    echo "host coherence gate FAILED (see above)" >&2
    exit 1
  ''}
  touch $out
''
