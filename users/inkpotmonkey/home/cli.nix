{ inputs, ... }:

{
  imports = [
    inputs.sops-nix.homeManagerModule

    ./base.nix
    ./shell.nix
    ./git.nix
    ./ssh.nix
  ];
}
