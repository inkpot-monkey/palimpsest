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
      };
    };
}
