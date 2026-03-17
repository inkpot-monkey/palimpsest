{ inputs, ... }:

{
  imports = [
    inputs.sops-nix.homeManagerModule
    ../identity.nix

    ./base.nix
    ./shell.nix
    ./git.nix
    ./ssh.nix
  ];
}
