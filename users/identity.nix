# Host-side system wiring for the contract (its ADR-0004): import the contract's umbrella
# nixos kit (the custom.users schema, realization, feature modules, insecure aggregator,
# exposed-host ban — all closed over the registry) and supply the one thing the contract
# leaves to the host: the `platform` *binding* (the secrets backend, Q7). Everything
# else now lives in the contract flake; this file is pure host glue.
{
  inputs,
  self,
  ...
}:
{
  imports = [ inputs.contract.nixosModules.default ];

  # The platform binding — the single place the system names its secrets backend, so a
  # feature resolves secrets host-agnostically. The contract ships only the interface;
  # the binding is shared with the home side via self.lib.platformBinding (contract ADR-0004 Q7).
  config.custom.platform = self.lib.platformBinding;
}
