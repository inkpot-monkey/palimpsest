{
  description = "A Nix-flake-based Bun typescript development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (builtins) attrValues;

      supportedSystems =
        [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forEachSupportedSystem = f:
        nixpkgs.lib.genAttrs supportedSystems
        (system: f { pkgs = import nixpkgs { inherit system; }; });

      devTools = pkgs:
        attrValues {
          inherit (pkgs) nil nixfmt node2nix;

          inherit (pkgs) yaml-language-server vscode-langservers-extracted;
          inherit (pkgs.nodePackages)
            typescript-language-server bash-language-server;
        };

    in {
      devShells = forEachSupportedSystem ({ pkgs }: {
        default = pkgs.mkShell {
          packages = attrValues { inherit (pkgs) bun; } ++ devTools pkgs;
        };
      });
    };
}
