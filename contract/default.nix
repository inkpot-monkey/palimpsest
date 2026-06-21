# The shared host↔user contract (ADR-0015): the schema both host and user agree
# on — identity, home-profile meta, and the feature/grant vocabulary that denial
# keys on. Exposed on `self.contract` so both the system and home evaluations
# consume one source. In-repo it is a shared module set; at the repo split
# (slice 07) it becomes a real flake input — a URL change, not a re-wire.
# Tracked: .scratch/host-user-contract/.
#
# The feature surfaces (`grantedOptions`, `featureMeta`, `featureGroups`,
# `featureConfigOptions`, `featureModules`) are all PROJECTIONS of the single
# `./features.nix` registry — plain `mapAttrs`/`filter`, no magic. One feature =
# one registry entry; the keys cannot drift because there is only one set of keys.
{ lib, ... }:
let
  registry = import ./features.nix { inherit lib; };

  # The privileged/host groups each feature grant confers (only features that have any).
  featureGroups = lib.mapAttrs (_: f: f.groups) (lib.filterAttrs (_: f: f ? groups) registry);

  # Groups a user may NOT obtain by merely declaring them in identity.extraGroups
  # (untrusted input) — they require a feature grant. Enforced by the realization clamp
  # (ADR-0015 threat model: powers come from grants, not raw data).
  privilegedGroups = [
    "docker"
    "podman"
    "wheel"
    "libvirtd"
    "kvm"
    "disk"
    "qemu-libvirtd"
  ];
in
{
  flake.contract = {
    identity = ./identity.nix;
    homeProfiles = ./home-profiles.nix;
    platform = ./platform.nix;
    # Host-invariant module mapping custom.users.<u> to system accounts. Closed over its
    # contract data here, so the shipped module needs neither `self` nor `inputs` (ADR-0020).
    realization = import ./realization.nix { inherit privilegedGroups featureGroups; };
    # Single writer of nixpkgs.config.permittedInsecurePackages (which shallow-merges,
    # so host + feature permits must funnel through one mergeable list option).
    insecurePackages = ./insecure-packages.nix;

    # The feature registry itself (single source of truth) and its projections.
    features = registry;

    # `granted.<f>.enable` grant options — default-closed (ADR-0015, mechanic 2).
    grantedOptions = lib.mapAttrs (_: f: { enable = lib.mkEnableOption f.grant; }) registry;

    # User-owned feature *configuration* options, merged into custom.users.<u> (so a
    # user writes e.g. `custom.users.<u>.gui.session`). Host-affecting params aggregate
    # across granted users in the realization — ADR-0019.
    featureConfigOptions = lib.foldl' lib.recursiveUpdate { } (
      map (f: f.config or { }) (lib.attrValues registry)
    );

    # Host-effects modules, imported alongside the realization so a user never writes
    # them (ADR-0018, slice 10). Today only gui has one.
    featureModules = lib.filter (m: m != null) (lib.mapAttrsToList (_: f: f.module or null) registry);

    # Static secret-disposition metadata. `secretBearing` marks features that pull a
    # secret onto a host, so an exposed host can refuse to grant them (ADR-0015 threat
    # model); `secretFiles` (when present) drives self.lib.featureRecipients.
    featureMeta = lib.mapAttrs (
      _: f:
      {
        secretBearing = f.secretBearing or false;
      }
      // lib.optionalAttrs (f ? secretFiles) { inherit (f) secretFiles; }
    ) registry;

    # The group policy (computed in the let above; the realization closes over them).
    inherit featureGroups privilegedGroups;
  };
}
