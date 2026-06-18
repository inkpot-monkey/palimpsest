{ lib, self, ... }:
{
  # Identity + home-profile schema come from the shared contract (ADR-0015), so the
  # system and home option paths describing the same data can't drift. The identity
  # value is populated from the system identity via `inherit identity` in
  # users/<user>/nixos/default.nix.
  options.identity = import self.contract.identity { inherit lib; };

  options.custom.home.profiles = import self.contract.homeProfiles { inherit lib; };

  # Platform interface (ADR-0015): home features resolve secrets through this, never
  # naming the host's backend directly. Bound here once — the single place the home
  # side names self.lib — so features stay host-agnostic.
  options.custom.platform = import self.contract.platform { inherit lib; };
  config.custom.platform = {
    secretFile = name: self.lib.getSecretFile name;
    secretPath = subpath: self.lib.getSecretPath subpath;
  };
}
