{
  description = "The host↔user contract — shared schema, host-invariant realization, derivation logic, and conformance kit (ADR-0015, ADR-0020). Depends only on nixpkgs lib.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      kit = import ./kit.nix { inherit (nixpkgs) lib; };
    in
    {
      # The umbrella kit (ADR-0020 Q2): one module per eval-side, closed over the
      # registry. A consumer imports these and binds the platform host-side.
      nixosModules.default = kit.nixosModule;
      homeModules.default = kit.homeModule;

      # The contract derivation functions (ADR-0020 Q4). The host applies the
      # fleet-bound ones (e.g. mkFeatureRecipients self.nixosConfigurations) itself.
      lib = kit.lib;

      # Data surface the host reads where it wires grants, recipients, and the safe set.
      inherit (kit)
        features
        featureMeta
        featureGroups
        privilegedGroups
        safeSet
        grantedOptions
        featureConfigOptions
        featureModules
        ;
    };
}
