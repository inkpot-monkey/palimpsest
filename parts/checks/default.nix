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
      };
    };
}
