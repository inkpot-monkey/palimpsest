{ lib, self, ... }:
{
  # Identity + home-profile schema come from the shared contract (ADR-0015), so the
  # system and home option paths describing the same data can't drift. The identity
  # value is populated from the system identity via `inherit identity` in
  # users/<user>/nixos/default.nix.
  options.identity = import self.contract.identity { inherit lib; };

  options.custom.home.profiles = import self.contract.homeProfiles { inherit lib; };
}
