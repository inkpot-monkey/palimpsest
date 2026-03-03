{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      apps = {
        dns = import ./dns { inherit pkgs self; };
        build-pi = import ./build-pi { inherit pkgs self; };
      };
    };
}
