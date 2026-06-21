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

  config.custom.platform = {
    secretFile = name: self.lib.getSecretFile name;
    secretPath = subpath: self.lib.getSecretPath subpath;
  };
}
