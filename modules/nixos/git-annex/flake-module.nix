_: {
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        git-annex = pkgs.callPackage ./tests/git-annex.nix { };
        git-annex-stateless = pkgs.callPackage ./tests/git-annex-stateless.nix { };
        git-annex-hybrid = pkgs.callPackage ./tests/git-annex-hybrid.nix { };
        git-annex-encryption = pkgs.callPackage ./tests/git-annex-encryption.nix { };
      };
    };
}
