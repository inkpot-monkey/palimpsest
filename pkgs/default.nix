# Custom packages, that can be defined similarly to ones from nixpkgs
# You can build them using 'nix build .#example'

pkgs: {
  vocabsieve = pkgs.libsForQt5.callPackage ./vocabsieve.nix { };
  n8n-mcp = pkgs.callPackage ./n8n-mcp.nix { };
}
