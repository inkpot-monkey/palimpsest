# Custom packages, that can be defined similarly to ones from nixpkgs
# You can build them using 'nix build .#example'

pkgs: {
  vocabsieve = pkgs.libsForQt5.callPackage ./vocabsieve.nix { };
  n8n-mcp = pkgs.callPackage ./n8n-mcp.nix { };
  finance-tools = pkgs.callPackage ./finance-tools { };
  kokoros = pkgs.callPackage ./kokoros { };
  brave-search = pkgs.callPackage ./brave-search.nix { };
  jmap-matrix-bridge = pkgs.callPackage ./jmap-matrix-bridge { };
}
