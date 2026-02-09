{
  pkgs ? import <nixpkgs> { },
}:

let
  finance-tools = pkgs.callPackage ./package.nix { };
in
pkgs.mkShell {
  inputsFrom = [ finance-tools ];

  packages = with pkgs; [
    fava
    python3Packages.python-lsp-server
    python3Packages.black
  ];

  shellHook = ''
    export PYTHONPATH=$PYTHONPATH:$(pwd)
    export BEANCOUNT_FILE=~/finance/main.bean
    echo "💰 Finance Tools Dev Shell"
    echo "Run 'fava' to start the server with local code."
  '';
}
