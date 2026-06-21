# The contract kit — a pure function of nixpkgs `lib`, assembling the entire host↔user
# contract: the feature registry and its projections, the contract lib functions, and
# the umbrella nixos/home modules (each closed over the registry). It depends on NOTHING
# but `lib` — no `self`, no `inputs` — which is what lets the contract be a standalone
# flake (./flake.nix wraps this). The host supplies only the `platform` *binding* and
# the package/display *bindings*; none of those live here (ADR-0020).
{ lib }:
let
  registry = import ./features.nix { inherit lib; };

  # --- projections of the single registry ---
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
  featureModules = lib.filter (m: m != null) (lib.mapAttrsToList (_: f: f.module or null) registry);
  featureMeta = lib.mapAttrs (
    _: f:
    {
      secretBearing = f.secretBearing or false;
    }
    // lib.optionalAttrs (f ? secretFiles) { inherit (f) secretFiles; }
  ) registry;

  realization = import ./realization.nix { inherit privilegedGroups featureGroups; };
  identityOptions = import ./identity.nix { inherit lib; };
  platformOptions = import ./platform.nix { inherit lib; };
  homeProfileOptions = import ./home-profiles.nix { inherit lib; };

  # --- contract lib functions (the derivation logic) ---

  # A feature is runtime/greeter-eligible iff it bears no secret, confers no privileged
  # group, and carries no host-executed payload (ADR-0018, slice 15).
  runtimeEligibleFeature =
    feature:
    let
      f = registry.${feature} or { };
    in
    !(f.secretBearing or false)
    && (lib.intersectLists (f.groups or [ ]) privilegedGroups == [ ])
    && !(f.execPayload or false);
  safeSet = lib.filter runtimeEligibleFeature (lib.attrNames registry);

  # Recipients-from-grants (ADR-0015, slice 06): for each secret-bearing feature's sops
  # file, the set of hosts that GRANT it — the single source of truth for .sops.yaml
  # recipients. Applied to a fleet's nixosConfigurations by the host (it reads the fleet).
  mkFeatureRecipients =
    nixosConfigurations:
    let
      secretFeatures = lib.filter (f: featureMeta.${f}.secretBearing or false) (
        lib.attrNames featureMeta
      );
      hostNames = lib.attrNames nixosConfigurations;
      hostGrants =
        host: feature:
        lib.any (u: u.granted.${feature}.enable or false) (
          lib.attrValues nixosConfigurations.${host}.config.custom.users
        );
    in
    lib.foldl' (
      acc: feature:
      let
        hosts = lib.filter (h: hostGrants h feature) hostNames;
      in
      lib.foldl' (a: file: a // { ${file} = lib.unique ((a.${file} or [ ]) ++ hosts); }) acc (
        featureMeta.${feature}.secretFiles or [ ]
      )
    ) { } secretFeatures;

  # The secret-bearing features an exposed host has been (wrongly) granted — the
  # exposed-host ban (ADR-0015 threat model). Must be empty.
  exposedHostOffenders =
    config:
    lib.concatMap (
      uname:
      let
        granted = config.custom.users.${uname}.granted;
      in
      lib.filter (
        fname: (granted.${fname}.enable or false) && (featureMeta.${fname}.secretBearing or false)
      ) (lib.attrNames featureMeta)
    ) (lib.attrNames config.custom.users);

  # The restricted projection of host state a user's home modules may read (ADR-0018,
  # slice 12): self-scoped, no hostName, no secret value.
  mkHostFacts = config: userName: {
    exposed = config.custom.host.exposed;
    platform = config.nixpkgs.hostPlatform.system;
    granted = config.custom.users.${userName}.granted;
  };

  # --- umbrella modules (closed over the projections above) ---

  # System kit: the custom.users schema, the platform INTERFACE (host binds it), the
  # exposed-host marker + ban, and the realization + insecure aggregator + feature
  # modules. ≈ the old users/identity.nix MINUS the platform binding (ADR-0020 Q2/Q7).
  nixosModule =
    { config, ... }:
    {
      imports = [
        realization
        ./insecure-packages.nix
      ]
      ++ featureModules;

      options.custom.users = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              identity = identityOptions;
              granted = grantedOptions;
            }
            // featureConfigOptions;
          }
        );
        default = { };
        description = "Per-user identity, grants, and feature configuration.";
      };
      options.custom.platform = platformOptions;
      options.custom.host.exposed = lib.mkEnableOption "an exposed/agent-facing host that may not be granted secret-bearing features";

      config.assertions = lib.optional config.custom.host.exposed (
        let
          offending = exposedHostOffenders config;
        in
        {
          assertion = offending == [ ];
          message = "exposed host '${config.networking.hostName}' must not be granted secret-bearing feature(s): ${lib.concatStringsSep ", " offending}";
        }
      );
    };

  # Home kit: the identity + home-profile vocabulary + the platform INTERFACE (host
  # binds it). ≈ the old modules/homeManager/options.nix MINUS the platform binding.
  homeModule = _: {
    options.identity = identityOptions;
    options.custom.home.profiles = homeProfileOptions;
    options.custom.platform = platformOptions;
  };
in
{
  # data surface
  features = registry;
  inherit
    featureMeta
    featureGroups
    privilegedGroups
    safeSet
    grantedOptions
    featureConfigOptions
    featureModules
    ;
  # lib functions
  lib = {
    inherit
      runtimeEligibleFeature
      safeSet
      mkFeatureRecipients
      exposedHostOffenders
      mkHostFacts
      ;
  };
  # umbrella modules
  inherit nixosModule homeModule;
}
