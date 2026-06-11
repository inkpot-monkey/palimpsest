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
        jmap_bridge = import ./jmap-bridge {
          inherit pkgs inputs self;
          homeserver = "dendrite";
        };
        jmap_bridge_tuwunel = import ./jmap-bridge {
          inherit pkgs inputs self;
          homeserver = "tuwunel";
        };
      };
    };
}
