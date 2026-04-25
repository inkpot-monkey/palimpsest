{
  config,
  lib,
  self, ...
}:

let
  cfg = config.custom.profiles.tailscale;
in
{
  options.custom.profiles.tailscale = {
    enable = lib.mkEnableOption "Tailscale with SOPS and Impermanence";

    advertiseSubnet = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "192.168.1.0/24";
      description = "The local subnet to advertise to the Tailnet. If null, subnet routing is disabled.";
    };

    acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to accept DNS settings from Tailscale.";
    };

    isExitNode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to act as an exit node.";
    };

    useExitNode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "100.64.0.1";
      description = "The IP address or name of the exit node to use. If null, no exit node is used.";
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "tag:server" ];
      description = "Tags to apply to the node. Often required for exit nodes or subnet routers in ACLs.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # 1. Conditionally enable IP forwarding ONLY if a subnet OR exit node is provided
        boot.kernel.sysctl = lib.mkIf (cfg.advertiseSubnet != null || cfg.isExitNode) {
          "net.ipv4.ip_forward" = 1;
          "net.ipv6.conf.all.forwarding" = 1;
        };

        # 2. SOPS Secret for Tailscale Auth Key
        sops.secrets.tailscale_key = {
          sopsFile = self.lib.getSecretPath "profiles/tailscale.yaml";
        };

        # 3. Tailscale Service Configuration
        services.tailscale = {
          enable = true;
          authKeyFile = config.sops.secrets.tailscale_key.path;

          extraUpFlags = [
            "--accept-dns=${lib.boolToString cfg.acceptDns}"
          ]
          ++ lib.optional (cfg.advertiseSubnet != null) "--advertise-routes=${cfg.advertiseSubnet}"
          ++ lib.optional cfg.isExitNode "--advertise-exit-node"
          ++ lib.optional (cfg.useExitNode != null) "--exit-node=${cfg.useExitNode}"
          ++ lib.optionals (cfg.tags != [ ]) (map (tag: "--advertise-tags=${tag}") cfg.tags);
        };

        # 4. Firewall Rules
        networking.firewall = {
          trustedInterfaces = [ "tailscale0" ];
          allowedUDPPorts = [ config.services.tailscale.port ];
        };
      }
      # 5. Impermanence Configuration
      {
        environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
          hideMounts = true;
          directories = [
            "/var/lib/tailscale"
          ];
        };
      }
    ]
  );
}
