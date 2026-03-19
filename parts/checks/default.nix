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
        transcriber = import ./transcriber {
          inherit pkgs inputs self;
        };
        media = import ./media {
          inherit pkgs inputs self;
        };
        transmission = import ./transmission {
          inherit pkgs inputs self;
        };
        flexget = import ./flexget {
          inherit pkgs inputs self;
        };
      };
    };
}
