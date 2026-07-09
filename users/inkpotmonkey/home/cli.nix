{
  inputs,
  self,
  ...
}:

{
  imports = [
    inputs.sops-nix.homeManagerModule
    # The sops binding for the contract platform interface (contract ADR-0005): realizes
    # custom.platform.secrets onto sops here, so feature modules never name sops.*.
    self.homeManagerModules.platformSops

    ./base.nix
    ./shell.nix
    ./git.nix
    ./ssh.nix
  ];
}
