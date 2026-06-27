{
  config,
  lib,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.impermanence;
in
{
  imports = [
    inputs.impermanence.nixosModules.impermanence
  ];

  options.custom.profiles.impermanence = {
    enable = lib.mkEnableOption "impermanence (persistence) configuration";
  };

  config = lib.mkIf cfg.enable {
    # Persistence configuration
    environment.persistence."/persistent" = {
      hideMounts = true;
      directories = [
        {
          directory = "/var/lib/private";
          mode = "0700";
        }
        {
          # DynamicUser service cache (mirrors /var/lib/private for the cache tier).
          # Without this, services like llama-cpp lose their model cache on every boot.
          directory = "/var/cache/private";
          mode = "0700";
        }
        "/etc/nixos"
        "/var/log"
        "/var/lib/nixos"
      ];
      files = [
        "/etc/machine-id"
        "/etc/ssh/ssh_host_ed25519_key"
        "/etc/ssh/ssh_host_ed25519_key.pub"
      ];
    };
  };
}
