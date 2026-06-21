# The contract kit — a pure function of nixpkgs `lib` that ASSEMBLES the contract from
# the registry: it computes the registry's projections (the data), then wires the
# derivation logic (./lib.nix) and the umbrella modules (./modules.nix) and returns the
# public surface. It depends on NOTHING but `lib` — no `self`, no `inputs` — which is
# what lets the contract be a standalone flake (./flake.nix wraps this). The host
# supplies only the `platform` binding and the package/display bindings (ADR-0020).
{ lib }:
let
  registry = import ./features.nix { inherit lib; };

  # --- projections of the single registry (the data) ---
  featureGroups = lib.mapAttrs (_: f: f.groups) (lib.filterAttrs (_: f: f ? groups) registry);
  privilegedGroups = [
    "docker"
    "podman"
    "wheel"
    "libvirtd"
    "kvm"
    "disk"
    "qemu-libvirtd"
  ];
  grantedOptions = lib.mapAttrs (_: f: { enable = lib.mkEnableOption f.grant; }) registry;
  featureConfigOptions = lib.foldl' lib.recursiveUpdate { } (
    map (f: f.config or { }) (lib.attrValues registry)
  );
  featureMeta = lib.mapAttrs (
    _: f:
    {
      secretBearing = f.secretBearing or false;
    }
    // lib.optionalAttrs (f ? secretFiles) { inherit (f) secretFiles; }
  ) registry;

  # --- closed-over modules + option fragments ---
  realization = import ./realization.nix { inherit privilegedGroups featureGroups; };
  identityOptions = import ./identity.nix { inherit lib; };
  platformOptions = import ./platform.nix { inherit lib; };
  homeProfileOptions = import ./home-profiles.nix { inherit lib; };

  # --- the two substantial pieces, split out for focus ---
  contractLib = import ./lib.nix {
    inherit
      lib
      registry
      privilegedGroups
      featureMeta
      ;
  };
  modules = import ./modules.nix {
    inherit
      lib
      realization
      identityOptions
      platformOptions
      homeProfileOptions
      grantedOptions
      featureConfigOptions
      ;
    inherit (contractLib) exposedHostOffenders;
  };
in
{
  # Public data surface — introspection API for consumers (a host grant matrix, the
  # greeter reading the safe set).
  features = registry;
  inherit
    featureMeta
    featureGroups
    privilegedGroups
    ;
  inherit (contractLib) safeSet;

  # Public derivation functions hosts consume (ADR-0020 Q4). The internal predicates
  # (runtimeEligibleFeature, exposedHostOffenders) stay internal to ./lib.nix.
  lib = {
    inherit (contractLib) mkFeatureRecipients mkHostFacts;
  };

  # The umbrella modules (one per eval-side).
  inherit (modules) nixosModule homeModule;
}
