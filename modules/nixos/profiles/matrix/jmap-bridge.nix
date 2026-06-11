{
  config,
  lib,
  self,
  ...
}:

let
  cfg = config.custom.profiles.matrix.jmap-bridge;
  domain = "matrix.palebluebytes.space";
in
{
  imports = [ self.nixosModules.jmap-bridge ];

  options.custom.profiles.matrix.jmap-bridge = {
    enable = lib.mkEnableOption "JMAP-to-Matrix bridge (email in Matrix)";
  };

  config = lib.mkIf cfg.enable {
    # --- Secrets ---
    sops.secrets.email_as_token = {
      sopsFile = self.lib.getSecretFile "matrix";
    };
    sops.secrets.email_hs_token = {
      sopsFile = self.lib.getSecretFile "matrix";
    };
    sops.secrets.email_encryption_key = {
      sopsFile = self.lib.getSecretFile "matrix";
    };
    # JMAP password for the declaratively-provisioned bridge user.
    sops.secrets.jmap_user_password = {
      sopsFile = self.lib.getSecretFile "matrix";
    };

    # --- Environment template ---
    sops.templates."jmap-bridge.env" = {
      content = ''
        MATRIX_AS_TOKEN=${config.sops.placeholder.email_as_token}
        MATRIX_HS_TOKEN=${config.sops.placeholder.email_hs_token}
      '';
    };

    # --- Registration Template ---
    sops.templates."jmap-registration.yaml" = {
      owner = "root";
      group = "root";
      content = ''
        id: jmap-bridge
        url: http://127.0.0.1:${toString config.services.jmap-bridge.port}
        as_token: ${config.sops.placeholder.email_as_token}
        hs_token: ${config.sops.placeholder.email_hs_token}
        sender_localpart: _jmap_bot
        namespaces:
          users:
          - exclusive: true
            regex: '@_jmap_.*'
          aliases: []
          rooms: []
      '';
    };

    # --- Bridge service (disabled by default) ---
    services.jmap-bridge = {
      enable = true;

      url = "http://127.0.0.1:8081";

      matrixUrl = "http://127.0.0.1:6167";
      environmentFile = config.sops.templates."jmap-bridge.env".path;
      encryptionKeyFile = config.sops.secrets.email_encryption_key.path;

      # Provision the bridge account declaratively instead of interactive !login.
      # jmapUsername is the Stalwart/JMAP login (the mailbox address).
      users = [
        {
          matrixId = "@inkpotmonkey:${domain}";
          jmapUsername = "thomas@palebluebytes.space";
          tokenFile = config.sops.secrets.jmap_user_password.path;
        }
      ];
    };

    systemd.services.jmap-bridge.environment.MATRIX_DOMAIN = domain;

    # --- Persistence ---
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/private/jmap-bridge"
      ];
    };
  };
}
