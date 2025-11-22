{
  description = "Java development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    language-servers = {
      url = "git+https://git.sr.ht/~bwolf/language-servers.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, language-servers }:
    let
      overlays = [ ];

      supportedSystems =
        [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      forEachSupportedSystem = f:
        nixpkgs.lib.genAttrs supportedSystems
        (system: f { pkgs = import nixpkgs { inherit overlays system; }; });

    in {
      packages = forEachSupportedSystem
        ({ pkgs }: { default = pkgs.callPackage ./default.nix { }; });

      devShells = forEachSupportedSystem ({ pkgs }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            jdk
            maven
            language-servers.packages.${system}.jdt-language-server
          ];
        };
      });
    };
}
