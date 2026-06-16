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
        # Run against tuwunel to match the production homeserver on kelpy.
        jmap_bridge = import ./jmap-bridge {
          inherit pkgs inputs self;
          homeserver = "tuwunel";
        };
      };
    };
}
