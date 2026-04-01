# Custom packages, that can be defined similarly to ones from nixpkgs
# You can build them using 'nix build .#example'

pkgs: {
  stump = pkgs.callPackage ./stump { };
  vocabsieve = pkgs.libsForQt5.callPackage ./vocabsieve.nix { };
  finance-tools = pkgs.callPackage ./finance-tools { };
  kokoros = pkgs.callPackage ./kokoros { };
  # brave-search = pkgs.callPackage ./brave-search.nix { };
  jmap-matrix-bridge = pkgs.callPackage ./jmap-matrix-bridge { };
  to-av1 = pkgs.callPackage ./to-av1 { };
  auto-sub = pkgs.callPackage ./auto-sub { };
  ocr-shot = pkgs.callPackage ./ocr { };
}
