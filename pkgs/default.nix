# Custom packages: wired via ./parts/packages.nix (flake-parts).
#   nix build .#packages.<system>.<name>    e.g. .#packages.x86_64-linux.annas_opds
# If meta.mainProgram is set, also: nix run .#<name>

{ pkgs, craneLib }: {
  stump = pkgs.callPackage ./stump { };
  vocabsieve = pkgs.libsForQt5.callPackage ./vocabsieve.nix { };
  finance-tools = pkgs.callPackage ./finance-tools { };
  kokoros = pkgs.callPackage ./kokoros { };
  annas_opds = pkgs.callPackage ./annas-opds { };
  # brave-search = pkgs.callPackage ./brave-search.nix { };
  jmap-matrix-bridge = pkgs.callPackage ./jmap-matrix-bridge { inherit craneLib; };
  # rust-mcp-server = pkgs.callPackage ./rust-mcp-server { };
  to-av1 = pkgs.callPackage ./to-av1 { };
  ocr-shot = pkgs.callPackage ./ocr { };
}
