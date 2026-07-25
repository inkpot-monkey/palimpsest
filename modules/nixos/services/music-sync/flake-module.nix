_: {
  perSystem =
    { pkgs, ... }:
    {
      checks = {
        music-sync = pkgs.callPackage ./tests/music-sync.nix { };
      };
    };
}
