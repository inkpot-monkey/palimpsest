{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        git-annex-home-manager = pkgs.callPackage ./tests/git-annex-home-manager.nix { inherit inputs; };
      };
    };
}
