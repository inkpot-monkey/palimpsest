{
  config,
  lib,
  pkgs,
  self,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.matrix.jmap-bridge;
  domain = config.services.matrix-tuwunel.settings.global.server_name;
in
{
  imports = [ inputs.jmap-bridge.nixosModules.jmap-bridge ];

  options.custom.profiles.matrix.jmap-bridge = {
    enable = lib.mkEnableOption "JMAP-to-Matrix bridge (email in Matrix)";
  };

  config = lib.mkIf cfg.enable {
    # --- Secrets ---
    # All JMAP/email credentials live in the mail secrets file (the bridge's
    # Matrix-side appservice tokens are email-bridge state, kept alongside the
    # JMAP login password rather than duplicated in matrix.yaml).
    sops.secrets.email_as_token = {
      sopsFile = self.lib.getSecretFile "mail";
    };
    sops.secrets.email_hs_token = {
      sopsFile = self.lib.getSecretFile "mail";
    };
    sops.secrets.email_encryption_key = {
      sopsFile = self.lib.getSecretFile "mail";
    };
    # JMAP login password for the declaratively-provisioned bridge user.
    sops.secrets.email_password = {
      sopsFile = self.lib.getSecretFile "mail";
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

      # Use the bridge flake's OWN package output (built against its pinned
      # nixpkgs) directly. We deliberately do NOT pull the bridge through the
      # fleet overlay: overlaying it would rebuild against the fleet nixpkgs and
      # change the store hash. This is the closure the bridge CI pushes to the
      # palebluebytes cachix, so kelpy substitutes it — see the jmap-bridge input
      # note in flake.nix.
      package = inputs.jmap-bridge.packages.${pkgs.stdenv.hostPlatform.system}.default;

      url = "http://127.0.0.1:8081";

      matrixUrl = "http://127.0.0.1:6167";
      # matrixUrl is loopback, so the module's matrixDomain default (its host,
      # 127.0.0.1) would mint wrong ghost mxids — pin it to the real server_name.
      matrixDomain = domain;
      environmentFile = config.sops.templates."jmap-bridge.env".path;
      encryptionKeyFile = config.sops.secrets.email_encryption_key.path;

      # Provision the bridge account declaratively instead of interactive !login.
      # jmapUsername is the Stalwart/JMAP login (the principal name, not the
      # email address).
      users = [
        {
          matrixId = "@${config.custom.profiles.matrix.adminLocalpart}:${domain}";
          jmapUsername = "thomas";
          tokenFile = config.sops.secrets.email_password.path;
          # Log in as the user to auto-accept the bridge's room invites (so each
          # email conversation doesn't need a manual "Start chatting").
          matrixPasswordFile = config.sops.secrets.matrix_admin_password.path;
        }
      ];
    };

    # Contribute this registration to tuwunel's appservice_dir wiring — see
    # the generic `appservices` consumer in matrix/default.nix.
    custom.profiles.matrix.appservices.jmap.registrationPath =
      config.sops.templates."jmap-registration.yaml".path;

    # Contribute to `matrix-reset`. No DM provisioner: the bridge self-provisions
    # its email rooms from the declarative `users` (matrixPasswordFile auto-accept),
    # so a fresh start only needs the bridge DB wiped and the service restarted.
    custom.profiles.matrix.resetState = [
      {
        service = "jmap-bridge.service";
        paths = [ "/var/lib/private/jmap-bridge" ];
      }
    ];

    # --- Persistence ---
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/private/jmap-bridge"
      ];
    };
  };
}
