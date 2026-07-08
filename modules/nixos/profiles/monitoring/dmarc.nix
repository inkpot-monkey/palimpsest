{
  config,
  lib,
  self,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-dmarc;
in
{
  imports = [ self.nixosModules.dmarc-metrics-exporter ];

  options.custom.profiles.monitoring-dmarc = {
    enable = lib.mkEnableOption "DMARC Metrics Exporter monitoring";

    imapUser = lib.mkOption {
      type = lib.types.str;
      default = "dmarc";
      description = ''
        The IMAP login for the DMARC report mailbox. Stalwart authenticates by
        account NAME, not email address (logging in as dmarc@… is denied), so
        this is the bare principal name — the `dmarc` account owns both
        dmarc@palebluebytes.space and dmarc@palebluebytes.xyz.
      '';
    };

    imapHost = lib.mkOption {
      type = lib.types.str;
      default = "mail.palebluebytes.space";
      description = ''
        Host running Stalwart's IMAP endpoint. The exporter runs on the
        monitoring host (rk1b), not the mail host, so this can't be localhost.
        `mail.palebluebytes.space` resolves to loopback on kelpy and to kelpy's
        tailnet IP elsewhere (networking.hosts), and matches the TLS cert on the
        implicit-TLS 993 listener from either.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.dmarc_imap_password = {
      # Lives in monitoring.yaml (decryptable by rk1b) rather than mail.yaml
      # (kelpy-only) so the exporter host isn't handed the Stalwart admin secret.
      sopsFile = self.lib.getSecretPath "profiles/monitoring.yaml";
      owner = "dmarc-metrics-exporter";
      group = "dmarc-metrics-exporter";
    };

    services.dmarc-metrics-exporter = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9797;
      imap = {
        host = cfg.imapHost;
        port = 993; # Stalwart IMAP (SSL/TLS implicit)
        user = cfg.imapUser;
        passwordFile = config.sops.secrets.dmarc_imap_password.path;
        mailbox = "INBOX";
      };
      pollInterval = 3600; # check every hour
    };

    # Persist the state directory across system rebuilds and reboots
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/dmarc-metrics-exporter"
      ];
    };
  };
}
