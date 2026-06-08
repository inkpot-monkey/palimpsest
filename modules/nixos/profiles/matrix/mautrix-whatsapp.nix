{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.matrix.whatsapp;
  botUsername = config.services.mautrix-whatsapp.settings.appservice.bot.username;
  serverName = config.services.matrix-conduit.settings.global.server_name;
  conduitUrl = "http://${config.services.matrix-conduit.settings.global.address}:${toString config.services.matrix-conduit.settings.global.port}";
  adminUsername = "inkpotmonkey";
in
{
  options.custom.profiles.matrix.whatsapp = {
    enable = lib.mkEnableOption "Mautrix-WhatsApp bridge for Matrix";
  };

  config = lib.mkIf cfg.enable {
    # --- Secrets ---
    sops.secrets.whatsapp_pickle_key = {
      sopsFile = self.lib.getSecretFile "matrix";
    };
    sops.secrets.whatsapp_as_token = {
      sopsFile = self.lib.getSecretFile "matrix";
      restartUnits = [
        "conduit.service"
        "mautrix-whatsapp.service"
      ];
    };
    sops.secrets.whatsapp_hs_token = {
      sopsFile = self.lib.getSecretFile "matrix";
      restartUnits = [
        "conduit.service"
        "mautrix-whatsapp.service"
      ];
    };

    # --- Environment template ---
    sops.templates."mautrix-whatsapp.env" = {
      content = ''
        ENCRYPTION_PICKLE_KEY=${config.sops.placeholder.whatsapp_pickle_key}
      '';
    };

    # --- Registration Template ---
    # mode 0400 (default) and owner=mautrix-whatsapp lets the bridge's
    # preStart cp the file before the service drops privileges.
    # Conduit receives this via LoadCredential so group is irrelevant.
    sops.templates."whatsapp-registration.yaml" = {
      owner = "mautrix-whatsapp";
      content = ''
        id: whatsapp
        url: http://localhost:29318
        as_token: ${config.sops.placeholder.whatsapp_as_token}
        hs_token: ${config.sops.placeholder.whatsapp_hs_token}
        sender_localpart: ${botUsername}
        namespaces:
          users:
          - exclusive: true
            regex: '@${botUsername}_.*'
      '';
    };

    # --- Bridge service ---
    services.mautrix-whatsapp = {
      enable = true;
      settings = {
        appservice = {
          bot = {
            username = "whatsapp";
          };
        };
        database = {
          type = "sqlite3-fk-wal";
          uri = "file:/var/lib/mautrix-whatsapp/mautrix-whatsapp.db?_txlock=immediate";
        };
        encryption = {
          allow = true;
          default = true;
          require = true;
          pickle_key = "$ENCRYPTION_PICKLE_KEY";
        };
        bridge = {
          permissions = {
            "${serverName}" = "user";
            "@${adminUsername}:${serverName}" = "admin";
          };
          double_puppet_server_map = {
            "${serverName}" = conduitUrl;
          };
          double_puppet_allow_discovery = true;
        };
      };
      environmentFile = config.sops.templates."mautrix-whatsapp.env".path;
    };

    systemd.services.mautrix-whatsapp.path = [ pkgs.gettext ];

    # Override the registration file with the one from Sops.
    # By running BEFORE the nixpkgs preStart script, our fresh registration file
    # (with current SOPS tokens) is copied to disk first. The nixpkgs module's
    # preStart script then runs yq to merge the fresh tokens perfectly from the
    # registration file into config.yaml, preventing the token staleness bug.
    systemd.services.mautrix-whatsapp.preStart = lib.mkBefore ''
      cp ${
        config.sops.templates."whatsapp-registration.yaml".path
      } /var/lib/mautrix-whatsapp/whatsapp-registration.yaml
      chmod 640 /var/lib/mautrix-whatsapp/whatsapp-registration.yaml
    '';

    # Conduit receives this registration via LoadCredential — see matrix/default.nix.
  };
}
