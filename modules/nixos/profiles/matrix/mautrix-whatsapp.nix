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

  # Builder for this bridge's own management-DM auto-provisioner (split out of the
  # central matrix-dm-provision so each bridge owns its auto-join wiring).
  mkDmService = import ./dm-provision.nix { inherit pkgs config; };
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
    sops.templates."mautrix-whatsapp.env" = {
      restartUnits = [ "mautrix-whatsapp.service" ];
      content = ''
        ENCRYPTION_PICKLE_KEY=${config.sops.placeholder.whatsapp_pickle_key}
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
        # bridgev2 schema (top-level, not under `bridge`; the old
        # `bridge.double_puppet_*` keys are dead in v26.05). This only points the
        # double-puppet login at the homeserver — it does NOT enable auto-join on
        # its own. Enable it with a one-time `login-matrix <access_token>` in the
        # bridge's management room. We deliberately avoid the declarative
        # `as_token` method: it requires putting @admin in this appservice's
        # namespace, which makes tuwunel route every room the admin is in
        # (including the jmap email rooms) to this bridge.
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

    # Auto-create the @whatsapp management DM (where `login` etc. are run). The
    # bridge bot auto-joins the invite. Ordered after the bridge so its appservice
    # link is up to receive the invite.
    #
    # encrypted = true is REQUIRED: this bridge sets encryption.require = true, so
    # in a plaintext room it drops every command as an unencrypted event ("can't
    # do anything"). The provisioner can't speak into an e2ee room, so the topic
    # carries the usage hint instead of an auto-sent welcome.
    systemd.services."matrix-dm-${botUsername}" = mkDmService {
      bot = botUsername;
      afterUnit = "mautrix-whatsapp.service";
      encrypted = true;
      topic = "WhatsApp bridge admin room — send `login` to pair your phone (QR/code), or `help` to list all commands.";
    };

    # Contribute to `matrix-reset`: the bridge service + its DM provisioner, and
    # the state dirs wiped for a from-scratch start (login + crypto, and the marker).
    custom.profiles.matrix.resetState = [
      {
        service = "mautrix-whatsapp.service";
        paths = [ "/var/lib/mautrix-whatsapp" ];
      }
      {
        service = "matrix-dm-${botUsername}.service";
        isDm = true;
        paths = [ "/var/lib/private/matrix-dm-${botUsername}" ];
      }
    ];

    # --- Persistence ---
    # The WhatsApp DB holds the QR-paired login session and the Olm/Megolm crypto
    # store; without persisting it a reboot forces a full re-pair. The DM marker is
    # persisted in lockstep with the homeserver (default.nix) so the DM isn't
    # re-created on every boot.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/mautrix-whatsapp";
          user = "mautrix-whatsapp";
          group = "mautrix-whatsapp";
          mode = "0750";
        }
        "/var/lib/private/matrix-dm-${botUsername}"
      ];
    };
  };
}
