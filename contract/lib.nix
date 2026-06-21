# The contract's derivation logic — pure functions over the registry and its
# projections, split out of kit.nix (thermo-nuclear review). `runtimeEligibleFeature`
# and `exposedHostOffenders` are internal (the kit's `safeSet` and the umbrella's
# exposed-host assertion close over them); `mkFeatureRecipients` / `mkHostFacts` are the
# public functions hosts consume (ADR-0020 Q4); `safeSet` is the derived value.
{
  lib,
  registry,
  privilegedGroups,
  featureMeta,
}:
let
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
in
{
  inherit runtimeEligibleFeature;

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
}
