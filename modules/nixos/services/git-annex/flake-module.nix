_: {
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        git-annex = pkgs.callPackage ./tests/git-annex.nix { };
        git-annex-cluster = pkgs.callPackage ./tests/git-annex-cluster.nix { };
        git-annex-hybrid = pkgs.callPackage ./tests/git-annex-hybrid.nix { };
        git-annex-encryption = pkgs.callPackage ./tests/git-annex-encryption.nix { };
        git-annex-keys = pkgs.callPackage ./tests/git-annex-keys.nix { };
        git-annex-init-hardening = pkgs.callPackage ./tests/git-annex-init-hardening.nix { };
        git-annex-shared-group = pkgs.callPackage ./tests/git-annex-shared-group.nix { };
      };
    };
}
