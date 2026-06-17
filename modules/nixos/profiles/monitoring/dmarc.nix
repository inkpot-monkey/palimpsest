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
      default = "dmarc@palebluebytes.space";
      description = "The IMAP username to check for DMARC reports.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.dmarc_imap_password = {
      sopsFile = self.lib.getSecretPath "profiles/mail.yaml";
      owner = "dmarc-metrics-exporter";
      group = "dmarc-metrics-exporter";
    };

    services.dmarc-metrics-exporter = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9797;
      imap = {
        host = "127.0.0.1";
        port = 993; # Local Stalwart IMAP port (SSL/TLS implicit)
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
