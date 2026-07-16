{ inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        git-annex-home-manager = pkgs.callPackage ./tests/git-annex-home-manager.nix { inherit inputs; };
        git-annex-ssh-key-routing = pkgs.callPackage ./tests/git-annex-ssh-key-routing.nix {
          inherit inputs;
        };
      };
    };
}
