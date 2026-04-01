{ self, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        stump = pkgs.callPackage ./tests/stump.nix { inherit self; };
      };
    };
}
