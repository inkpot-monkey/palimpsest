{
  config,
  lib,
  options,
  ...
}:

{
  config = lib.mkMerge [
    {
      # 1. SOPS Secret for Tailscale Auth Key
      sops.secrets.tailscale_key = {
        sopsFile = config.sops.defaultSopsFile;
      };

      # 2. Tailscale Service Configuration
      services.tailscale = {
        enable = true;

        # Point to the decrypted secret path managed by SOPS
        authKeyFile = config.sops.secrets.tailscale_key.path;

        # Accept Tailscale MagicDNS and route settings
        extraUpFlags = [ "--accept-dns=true" ];
      };

      # 3. Firewall Rules
      networking.firewall = {
        # Always trust traffic coming over the Tailscale tunnel
        trustedInterfaces = [ "tailscale0" ];

        # Allow the Tailscale daemon to establish peer-to-peer connections
        allowedUDPPorts = [ config.services.tailscale.port ];
      };
    }
    (lib.optionalAttrs (options.environment ? persistence) {
      # 4. Impermanence Configuration
      # This guarantees Tailscale keeps its machine IP and identity across root wipes
      environment.persistence."/persistent" = {
        hideMounts = true;
        directories = [
          "/var/lib/tailscale"
        ];
      };
    })
  ];
}
