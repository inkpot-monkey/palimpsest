# Host-side system wiring for the contract (its ADR-0004): import the contract's umbrella
# nixos kit (the custom.users schema, realization, feature modules, insecure aggregator,
# exposed-host ban — all closed over the registry) and supply the one thing the contract
# leaves to the host: the `platform` *binding* (the secrets backend, Q7). Everything
# else now lives in the contract flake; this file is pure host glue.
{
  inputs,
  ...
}:
{
  imports = [ inputs.contract.nixosModules.default ];
  # The platform seam is home-side only now (secrets are a home concern) — declared + bound in
  # modules/homeManager/options.nix. The system no longer sets custom.platform (nothing read it).
}
