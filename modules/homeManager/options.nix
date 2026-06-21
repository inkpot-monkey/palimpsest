# Host-side home wiring for the contract (ADR-0020): import the contract's umbrella home
# kit (identity + home-profile vocabulary + the platform interface) and supply the
# host's `platform` binding (Q7). The contract ships only the interface; the secrets
# backend is named here. The identity value is populated from the system identity via
# `inherit identity` in users/<user>/nixos/default.nix.
{
  self,
  inputs,
  ...
}:
{
  imports = [ inputs.contract.homeModules.default ];

  # Same host platform binding as the system side, shared via self.lib.platformBinding
  # so the secrets-backend wiring lives in exactly one place (ADR-0020 Q7).
  config.custom.platform = self.lib.platformBinding;
}
