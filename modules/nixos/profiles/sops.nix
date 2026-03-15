{
  config,
  lib,
  inputs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.sops;
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  options.custom.profiles.sops = {
    enable = lib.mkEnableOption "SOPS-nix configuration";
  };

  config = lib.mkIf cfg.enable {
    sops = {
      defaultSopsFile = self + "/secrets/secrets.yaml";
      defaultSopsFormat = "yaml";
      useSystemdActivation = true;
    };
  };
}
