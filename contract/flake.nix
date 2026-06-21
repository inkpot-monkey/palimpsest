{
  description = "The host↔user contract — shared schema, host-invariant realization, derivation logic, and conformance kit (ADR-0015, ADR-0020). Depends only on nixpkgs lib.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      kit = import ./kit.nix { inherit (nixpkgs) lib; };
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      # The umbrella kit (ADR-0020 Q2): one module per eval-side, closed over the
      # registry. A consumer imports these and binds the platform host-side.
      nixosModules.default = kit.nixosModule;
      homeModules.default = kit.homeModule;

      # The contract derivation functions (ADR-0020 Q4). The host applies the
      # fleet-bound ones (e.g. mkFeatureRecipients self.nixosConfigurations) itself.
      inherit (kit) lib;

      # Data surface the host reads where it wires grants, recipients, and the safe set.
      inherit (kit)
        features
        featureMeta
        featureGroups
        privilegedGroups
        safeSet
        ;

      # The contract's own conformance suite (ADR-0020 Q5): proves the contract's
      # promises against synthetic users on synthetic systems built from the umbrella —
      # no host repo. Independent CI; the host keeps the coherence gate + display VM.
      checks = forAllSystems (system: {
        conformance = import ./conformance {
          inherit system;
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
          contractModule = self.nixosModules.default;
          inherit (self) safeSet featureGroups privilegedGroups;
          nixosSystem = nixpkgs.lib.nixosSystem;
        };
      });
    };
}
