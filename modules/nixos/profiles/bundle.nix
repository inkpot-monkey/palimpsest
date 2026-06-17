{ lib, self, ... }:
# The "kitchen sink" a full host imports, then turns features on via
# `custom.profiles.*.enable`. Its contents are DERIVED from the single profile
# catalogue (`flake.nixosProfiles`, in ./default.nix) so the two can never drift —
# add a profile to the catalogue and it joins the bundle automatically.
#
# Excluded from the generic bundle (kept opt-in / à-la-carte):
#   - bundle / pi-bundle : the kitchen-sink modules themselves (self-reference)
#   - pi / hifiberry / hifi : Raspberry-Pi hardware profiles (pulled in via pi-bundle)
#   - piBuilder : aarch64 build-offload, enabled explicitly per host
let
  excluded = [
    "bundle"
    "pi-bundle"
    "pi"
    "hifiberry"
    "hifi"
    "piBuilder"
  ];
  catalogue = removeAttrs self.nixosProfiles excluded;
in
{
  # `lib.collect isPath` flattens nested groups (e.g. monitoring.{client,server,…})
  # into the flat list of module paths that `imports` expects.
  imports = lib.collect builtins.isPath catalogue;
}
