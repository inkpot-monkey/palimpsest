{ self, inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      apps = {
        dns = import ./dns { inherit pkgs self inputs; };
        build-pi = import ./build-pi { inherit pkgs self; };
      };
    };
}
