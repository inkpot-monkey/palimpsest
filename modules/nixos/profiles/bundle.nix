{ lib, self, ... }:
# The "kitchen sink" a full host imports, then turns features on via
# `custom.profiles.*.enable`. Its contents are DERIVED from the single profile
# catalogue (`flake.nixosProfiles`, in ./default.nix) so the two can never drift —
# add a profile to the catalogue and it joins the bundle automatically.
#
# Excluded from the generic bundle (kept opt-in / à-la-carte):
#   - bundle / pi-bundle : the kitchen-sink modules themselves (self-reference). The Pi
#     hardware profiles (pi/hifiberry/hifi) are not in the catalogue at all — pi-bundle
#     imports them directly — so they don't need excluding here.
#   - piBuilder : aarch64 build-offload, enabled explicitly per host
let
  excluded = [
    "bundle"
    "pi-bundle"
    "piBuilder"
  ];
  catalogue = removeAttrs self.nixosProfiles excluded;
in
{
  # `lib.collect isPath` flattens nested groups (e.g. monitoring.{client,server,…})
  # into the flat list of module paths that `imports` expects.
  imports = lib.collect builtins.isPath catalogue;
}
