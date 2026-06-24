{
  config,
  lib,
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
    # The relay bot account's password. Lives in the matrix secrets file; the
    # operator creates the @claude-relay account and adds this key to stash.
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
    };

    # Persist the session<->room map across reboots (ephemeral-resumable, slice 05).
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [ "/var/lib/claude-relay" ];
    };
  };
}
