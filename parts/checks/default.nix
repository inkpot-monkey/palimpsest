{ inputs, self, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        affine = import ./affine {
          inherit pkgs inputs self;
        };
        networking = import ./networking {
          inherit pkgs inputs self;
        };
        annas_opds = import ./annas-opds {
          inherit pkgs;
        };
        # jmap_bridge VM check moved to the bridge's own repo
        # (inputs.jmap-bridge.checks); its CI owns the round-trip test now.
        # Host↔user contract (ADR-0015): gui grant drives the feature; deny is a no-op.
        host_user_contract = import ./host-user-contract {
          inherit pkgs self;
        };
        # Runtime VM smoke for the gui-session union (ADR-0016): one host, two gui
        # users with different sessions ⇒ both plasma sessions offered live.
        host_user_contract_vm = import ./host-user-contract-vm {
          inherit pkgs self;
        };
      };
    };
}
