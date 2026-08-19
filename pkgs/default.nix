# Custom packages: wired via ./parts/packages.nix (flake-parts).
#   nix build .#packages.<system>.<name>    e.g. .#packages.x86_64-linux.annas_opds
# If meta.mainProgram is set, also: nix run .#<name>

{ pkgs, inputs }: {
  # stump: TEMPORARY 0.1.6 override, ahead of the nixpkgs PIN (which is on 0.1.5;
  # nixpkgs itself took 0.1.6 on 2026-08-08). 0.1.5's KOReader progress-fetch
  # route 500s, which is the round-trip #116 exists to build. Delete this line
  # and pkgs/stump once the pin has stump >= 0.1.6 — see the removal condition at
  # the top of pkgs/stump/default.nix (#111/#116).
  stump = pkgs.callPackage ./stump { };
  # vocabsieve = pkgs.libsForQt5.callPackage ./vocabsieve.nix { }; # broken: its dep
  # gst_all_1.gst-vaapi was removed in GStreamer 1.28 (not an in-place upgrade); disabled
  # so it stops failing `nix flake check`. Re-enable once vocabsieve moves off gst-vaapi.
  # supernote: the fork (github:inkpot-monkey/supernote, rev-pinned — #112 moved this to
  # upstream and palimpsest#145 moved it back for the device realtime channel; the
  # vendored fork), packaged from the `supernote` flake input; buildPythonApplication on
  # python313. See pkgs/supernote.
  supernote = pkgs.callPackage ./supernote { src = inputs.supernote; };
  finance-tools = pkgs.callPackage ./finance-tools { };
  kokoros = pkgs.callPackage ./kokoros { };
  annas_opds = pkgs.callPackage ./annas-opds { };
  # brave-search = pkgs.callPackage ./brave-search.nix { };
  # jmap-matrix-bridge now ships from its own repo, consumed directly as
  # inputs.jmap-bridge.packages.<system> (see modules/nixos/profiles/matrix/jmap-bridge.nix).
  # rust-mcp-server = pkgs.callPackage ./rust-mcp-server { };
  to-av1 = pkgs.callPackage ./to-av1 { };
  ocr-shot = pkgs.callPackage ./ocr { };
}
