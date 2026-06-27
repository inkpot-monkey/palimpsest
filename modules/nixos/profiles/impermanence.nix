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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Persistence configuration
        environment.persistence."/persistent" = {
          hideMounts = true;
          directories = [
            {
              directory = "/var/lib/private";
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
      }

      # DynamicUser service cache (mirrors /var/lib/private for the cache tier).
      # Only needed when /var/cache is the ephemeral root — when it's a separately-mounted
      # persistent filesystem (e.g. NVMe on rk1b) it is already persistent and the
      # impermanence bind-mount would both be wrong and require neededForBoot on the NVMe.
      (lib.mkIf (!(config.fileSystems ? "/var/cache")) {
        environment.persistence."/persistent".directories = [
          {
            directory = "/var/cache/private";
            mode = "0700";
          }
        ];
      })
    ]
  );
}
