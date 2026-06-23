{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.matrix.hookshot;
  domain = config.services.matrix-tuwunel.settings.global.server_name;
  adminLocalpart = config.custom.profiles.matrix.adminLocalpart;
  matrixSecrets = self.lib.getSecretFile "matrix";

  user = "matrix-hookshot";
  stateDir = "/var/lib/matrix-hookshot";

  # Homeserver client-server API (loopback; tuwunel binds here — see matrix/default.nix).
  homeserverUrl = "http://${builtins.head config.services.matrix-tuwunel.settings.global.address}:${toString (builtins.head config.services.matrix-tuwunel.settings.global.port)}";

  # Appservice port the homeserver dials (loopback only — must match the `url`
  # in the registration below). Not a public service, so it stays out of settings.nix.
  appservicePort = 9993;

  # Public webhook/oauth listener. GitHub + generic POSTs and the OAuth callback
  # land here via Caddy (hookshot.<domain> → 127.0.0.1:webhookPort). Driven by
  # settings.nix so the proxy + DNS pick it up automatically.
  webhookPort = settings.services.public.hookshot.port;
  publicUrl = "https://hookshot.${config.networking.domain}";

  # Builder for this bridge's own management-DM auto-provisioner (split out of the
  # central matrix-dm-provision so each bridge owns its auto-join wiring).
  mkDmService = import ./dm-provision.nix { inherit pkgs config; };
in
{
  options.custom.profiles.matrix.hookshot = {
    enable = lib.mkEnableOption ''
      matrix-hookshot — GitHub (personal notifications + repo events), generic
      inbound webhooks, and RSS/Atom feeds bridged into Matrix
    '';
  };

  config = lib.mkIf cfg.enable {
    # Dedicated hardened service account (not root, unlike the nixpkgs module
    # default). A static system user — not DynamicUser — so sops can chown the
    # rendered config/registration/key to it (a DynamicUser's uid is unknown at
    # activation, the classic sops + DynamicUser clash).
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = stateDir;
      createHome = false;
      description = "matrix-hookshot service user";
    };
    users.groups.${user} = { };

    # --- Secrets (all in the matrix profile secrets file) ---
    # as/hs tokens are the appservice's Matrix credentials; the rest describe the
    # one-time-created GitHub App (id/key/webhook secret/OAuth client). You add
    # the values to secrets/profiles/matrix.yaml after creating the App — see the
    # ADR / module README for the exact GitHub App setup.
    sops.secrets =
      lib.genAttrs
        [
          "hookshot_as_token"
          "hookshot_hs_token"
          "hookshot_github_app_id"
          "hookshot_github_private_key"
          "hookshot_github_webhook_secret"
          "hookshot_github_oauth_client_id"
          "hookshot_github_oauth_client_secret"
        ]
        (_: {
          sopsFile = matrixSecrets;
          owner = user;
          restartUnits = [ "matrix-hookshot.service" ];
        });

    # --- config.yml (rendered via sops, NOT services.matrix-hookshot.settings) ---
    # The nixpkgs module renders `settings` into a world-readable Nix store file,
    # but hookshot keeps the webhook secret and OAuth client_secret INLINE (only
    # the App key takes a path). So we template the whole config and override
    # ExecStart to consume it — the same secret-handling stance as the jmap and
    # whatsapp registrations.
    sops.templates."hookshot-config.yml" = {
      owner = user;
      restartUnits = [ "matrix-hookshot.service" ];
      content = ''
        bridge:
          domain: ${domain}
          url: ${homeserverUrl}
          mediaUrl: https://${domain}
          port: ${toString appservicePort}
          bindAddress: 127.0.0.1
        passFile: ${stateDir}/passkey.pem
        logging:
          level: info
        listeners:
          - port: ${toString webhookPort}
            bindAddress: 127.0.0.1
            resources:
              - webhooks
        github:
          auth:
            id: ${config.sops.placeholder.hookshot_github_app_id}
            privateKeyFile: ${config.sops.secrets.hookshot_github_private_key.path}
          webhook:
            secret: ${config.sops.placeholder.hookshot_github_webhook_secret}
          oauth:
            client_id: ${config.sops.placeholder.hookshot_github_oauth_client_id}
            client_secret: ${config.sops.placeholder.hookshot_github_oauth_client_secret}
            redirect_uri: ${publicUrl}/oauth
        generic:
          enabled: true
          urlPrefix: ${publicUrl}/webhook/
          userIdPrefix: _webhooks_
          allowJsTransformationFunctions: true
          waitForComplete: false
        feeds:
          enabled: true
          pollIntervalSeconds: 600
        permissions:
          - actor: "@${adminLocalpart}:${domain}"
            services:
              - service: "*"
                level: admin
      '';
    };

    # --- Appservice registration (sops-rendered; shared verbatim with tuwunel) ---
    # hookshot reads as/hs tokens + namespaces here; tuwunel loads the identical
    # file from appservice_dir. Ghost prefixes: _github_ (GitHub authors) and
    # _webhooks_ (generic-hook senders). The `hookshot` sender_localpart is
    # implicitly granted by tuwunel even though it sits outside the namespaces.
    sops.templates."hookshot-registration.yaml" = {
      owner = user;
      restartUnits = [
        "matrix-hookshot.service"
        "tuwunel.service"
      ];
      content = ''
        id: hookshot
        url: http://127.0.0.1:${toString appservicePort}
        as_token: ${config.sops.placeholder.hookshot_as_token}
        hs_token: ${config.sops.placeholder.hookshot_hs_token}
        sender_localpart: hookshot
        rate_limited: false
        namespaces:
          users:
            - exclusive: true
              regex: '@_github_.*'
            - exclusive: true
              regex: '@_webhooks_.*'
          aliases: []
          rooms: []
      '';
    };

    services.matrix-hookshot = {
      enable = true;
      registrationFile = config.sops.templates."hookshot-registration.yaml".path;
      serviceDependencies = [ "tuwunel.service" ];
      # passFile lives under the (persisted) StateDirectory; the module's preStart
      # generates it on first run. Everything else in `settings` is unused — we
      # drive the real config via the sops template + ExecStart override below.
      settings.passFile = "${stateDir}/passkey.pem";
    };

    systemd.services.matrix-hookshot.serviceConfig = {
      ExecStart = lib.mkForce (
        "${config.services.matrix-hookshot.package}/bin/matrix-hookshot "
        + "${config.sops.templates."hookshot-config.yml".path} "
        + "${config.sops.templates."hookshot-registration.yaml".path}"
      );

      User = user;
      Group = user;
      StateDirectory = "matrix-hookshot";
      StateDirectoryMode = "0750";

      # Internet-facing → harden tightly. Only needs the network and its state dir.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ stateDir ];
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
    };

    # Contribute the registration to tuwunel's appservice_dir wiring — see the
    # generic `appservices` consumer in matrix/default.nix.
    custom.profiles.matrix.appservices.hookshot.registrationPath =
      config.sops.templates."hookshot-registration.yaml".path;

    # Auto-create the @hookshot admin DM (where `github login` etc. are run). The
    # bridge bot auto-joins the invite. Ordered after the bridge so its appservice
    # link is up to receive the invite.
    systemd.services."matrix-dm-hookshot" = mkDmService {
      bot = "hookshot";
      afterUnit = "matrix-hookshot.service";
    };

    # Contribute to `matrix-reset`: the bridge service + its DM provisioner, and
    # the state dirs wiped for a from-scratch start (OAuth/passkey, and the marker).
    custom.profiles.matrix.resetState = [
      {
        service = "matrix-hookshot.service";
        paths = [ stateDir ];
      }
      {
        service = "matrix-dm-hookshot.service";
        isDm = true;
        paths = [ "/var/lib/private/matrix-dm-hookshot" ];
      }
    ];

    # --- Persistence ---
    # passkey.pem encrypts the stored GitHub/OAuth tokens; lose it and every
    # logged-in connection must be re-authed. Persist the whole state dir. The DM
    # marker is persisted in lockstep with the homeserver (default.nix).
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = stateDir;
          inherit user;
          group = user;
          mode = "0750";
        }
        "/var/lib/private/matrix-dm-hookshot"
      ];
    };
  };
}
