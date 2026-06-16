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
  bridgePort = config.services.mautrix-whatsapp.settings.appservice.port;
  serverName = config.services.matrix-tuwunel.settings.global.server_name;
  homeserverUrl = "http://${builtins.head config.services.matrix-tuwunel.settings.global.address}:${toString (builtins.head config.services.matrix-tuwunel.settings.global.port)}";
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;
  # Dots escaped for the appservice namespace regex (full-MXID match).
  serverNameRe = builtins.replaceStrings [ "." ] [ "\\." ] serverName;
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
        "tuwunel.service"
        "mautrix-whatsapp.service"
      ];
    };
    sops.secrets.whatsapp_hs_token = {
      sopsFile = self.lib.getSecretFile "matrix";
      restartUnits = [
        "tuwunel.service"
        "mautrix-whatsapp.service"
      ];
    };

    # --- Environment template ---
    # LOGIN_SHARED_SECRET is consumed by the nixpkgs module's pre-start, which
    # writes it to `double_puppet.secrets.<domain>`. The `as_token:` form tells
    # the bridge to double-puppet via m.login.application_service (tuwunel
    # advertises that flow) — so portal rooms are auto-joined as the admin
    # instead of leaving an invite to accept. Requires the admin to sit in the
    # appservice namespace (see the registration below).
    sops.templates."mautrix-whatsapp.env" = {
      restartUnits = [ "mautrix-whatsapp.service" ];
      content = ''
        ENCRYPTION_PICKLE_KEY=${config.sops.placeholder.whatsapp_pickle_key}
        MAUTRIX_WHATSAPP_BRIDGE_LOGIN_SHARED_SECRET=as_token:${config.sops.placeholder.whatsapp_as_token}
      '';
    };

    # --- Registration Template ---
    # mode 0400 (default) and owner=mautrix-whatsapp lets the bridge's
    # preStart cp the file before the service drops privileges.
    # tuwunel loads this declaratively via appservice_dir — see matrix/default.nix.
    sops.templates."whatsapp-registration.yaml" = {
      owner = "mautrix-whatsapp";
      content = ''
        id: whatsapp
        url: http://127.0.0.1:${toString bridgePort}
        as_token: ${config.sops.placeholder.whatsapp_as_token}
        hs_token: ${config.sops.placeholder.whatsapp_hs_token}
        sender_localpart: ${botUsername}
        namespaces:
          users:
          - exclusive: true
            regex: '@${botUsername}_.*'
          # Non-exclusive: lets the appservice double-puppet the admin (auto-join
          # portals) without claiming sole ownership of the human's account.
          - exclusive: false
            regex: '@${adminLocalpart}:${serverNameRe}'
      '';
    };

    # --- Bridge service ---
    services.mautrix-whatsapp = {
      enable = true;
      settings = {
        homeserver = {
          address = homeserverUrl;
          domain = serverName;
        };
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
            "@${adminLocalpart}:${serverName}" = "admin";
          };
        };
        # bridgev2 schema (top-level, not under `bridge`). The `secrets` entry is
        # injected at runtime from the env file so the token stays out of the Nix
        # store — see the env template above.
        double_puppet = {
          servers = {
            "${serverName}" = homeserverUrl;
          };
          allow_discovery = true;
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

    # Contribute this registration to tuwunel's appservice_dir wiring — see
    # the generic `appservices` consumer in matrix/default.nix.
    custom.profiles.matrix.appservices.whatsapp.registrationPath =
      config.sops.templates."whatsapp-registration.yaml".path;
  };
}
