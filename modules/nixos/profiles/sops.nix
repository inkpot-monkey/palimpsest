{
  config,
  lib,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.sops;
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  options.custom.profiles.sops = {
    enable = lib.mkEnableOption "SOPS-nix configuration";
    sshKey = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SOPS identity derivation from host SSH key";
    };
  };

  config = lib.mkIf cfg.enable {
    sops = {
      defaultSopsFormat = "yaml";
      useSystemdActivation = true;

      age = {
        # Automatically derive the age key from the host SSH key
        sshKeyPaths = lib.mkIf cfg.sshKey [ "/etc/ssh/ssh_host_ed25519_key" ];
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = true;
      };
    };
  };
}
