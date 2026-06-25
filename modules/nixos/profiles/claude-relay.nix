{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:

# Profile wiring for the Claude relay (ADR-0025). The service module
# (modules/nixos/services/claude-relay) carries the daemon + options; this
# profile wires it to the local homeserver and reuses inkpotmonkey's ~/.claude
# login for the claude sessions (the same account AionUi uses). Enable only where
# tuwunel runs (kelpy). Slice 06 (deploy beside AionUi + real-claude smoke) and
# slice 07 (retire AionUi) remain operator steps.

let
  cfg = config.custom.profiles.claude-relay;
  matrixServer = "matrix.${config.networking.domain}";
  matrixPort = settings.services.public.matrix.port;

  # The Claude logo (Simple Icons, the standard pinnable brand-asset source),
  # rasterised to the app-icon look: the white sunburst on the brand terracotta
  # square. Applied by the relay to the bot, the Claude space, and every relay room.
  claudeLogoSvg = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/simple-icons/simple-icons/15.18.0/icons/claude.svg";
    hash = "sha256-LW/aeesY3czKNbeZ7rPOzg36vCJSDOOxCr0lZo35+pM=";
  };
  claudeAvatar =
    pkgs.runCommand "claude-avatar.png"
      {
        nativeBuildInputs = [
          pkgs.resvg
          pkgs.imagemagick
        ];
      }
      ''
        resvg --width 340 ${claudeLogoSvg} glyph.png
        magick -size 512x512 xc:'#D97757' \( glyph.png -channel RGB -negate \) \
          -gravity center -composite "$out"
      '';
in
{
  imports = [ self.nixosModules.claude-relay ];

  options.custom.profiles.claude-relay = {
    enable = lib.mkEnableOption "the Claude relay (Matrix interface to persistent claude sessions, ADR-0025)";

    allowedSender = lib.mkOption {
      type = lib.types.str;
      default = "@inkpotmonkey:${matrixServer}";
      defaultText = lib.literalExpression ''"@inkpotmonkey:matrix.''${config.networking.domain}"'';
      description = "The sole MXID allowed to drive the relay (enforced in-process, ADR-0025).";
    };
  };

  config = lib.mkIf cfg.enable {
    # The relay bot account is created declaratively (registrationTokenFile below),
    # so deploy needs only this password secret in stash — no manual account setup.
    assertions = [
      {
        assertion = config.custom.profiles.matrix.enable;
        message = "custom.profiles.claude-relay needs the matrix profile (local tuwunel + registration_token) on the same host.";
      }
    ];

    # The relay bot account's password. Lives in the matrix secrets file (stash).
    sops.secrets.claude_relay_bot_password.sopsFile = self.lib.getSecretFile "matrix";

    services.claude-relay = {
      enable = true;
      # Run as inkpotmonkey to reuse its ~/.claude subscription login (the account
      # AionUi already uses); the relay merges its hooks into that settings.json.
      serviceUser = "inkpotmonkey";
      group = "users";
      createUser = false;
      home = config.users.users.inkpotmonkey.home;
      homeserver = "http://127.0.0.1:${toString matrixPort}";
      user = "claude-relay";
      inherit (cfg) allowedSender;
      passwordFile = config.sops.secrets.claude_relay_bot_password.path;
      # Auto-create @claude-relay via the homeserver's shared registration token
      # (the same secret tuwunel-register-admin uses).
      registrationTokenFile = config.sops.secrets.registration_token.path;
      # The Claude logo on the bot, the Claude space, and every relay room.
      avatarFile = claudeAvatar;
      # Auto-join the operator (@inkpotmonkey) into the bot's rooms — tuwunel has
      # no server-side force-join, so the relay accepts on the operator's behalf
      # using inkpotmonkey's existing admin password. allowedSender's localpart
      # (inkpotmonkey) is the operator account this password belongs to.
      operatorPasswordFile = config.sops.secrets.matrix_admin_password.path;
    };

    # Order after the admin registration so inkpotmonkey (not the bot) wins
    # grant_admin_to_first_user, and only attempt once tuwunel is up.
    systemd.services.claude-relay-register = {
      after = [
        "tuwunel.service"
        "tuwunel-register-admin.service"
      ];
      requires = [ "tuwunel.service" ];
    };

    # Wire the relay into `matrix-reset` so a from-scratch wipe stays coherent.
    # Without this, reset deletes the homeserver (so @claude-relay, the control
    # room and every session room vanish) but the relay keeps running against a
    # dead account with a state.json pointing at deleted rooms. Listing both units
    # makes reset stop them, wipe /var/lib/claude-relay (the persisted control-room
    # + session map), and on restart re-run claude-relay-register — recreating
    # @claude-relay (after the admin re-registers) before the relay logs back in.
    # Not isDm: started right after tuwunel/admin (the After= ordering on
    # claude-relay-register holds), not deferred to the post-bridge DM phase.
    custom.profiles.matrix.resetState = [
      {
        service = "claude-relay-register.service";
        paths = [ "/var/lib/claude-relay" ];
      }
      { service = "claude-relay.service"; }
    ];

    # Persist the session<->room map across reboots (ephemeral-resumable, slice 05).
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [ "/var/lib/claude-relay" ];
    };
  };
}
