{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.mail-sieve;
  mailCfg = config.custom.profiles.mail;

  # Stalwart's INTERNAL JMAP listener. profiles/mail/default.nix binds it to
  # 127.0.0.1:8081, which is the only way in from this host — and the reason the
  # provisioner rewrites the origin out of the session document's URL templates
  # (they advertise the public name on this internal port). Same trap the
  # Gmail-migration runbook records for apiUrl.
  jmapUrl = "http://127.0.0.1:8081";

  scriptFile = pkgs.writeText "${cfg.scriptName}.sieve" cfg.script;

  provision = pkgs.writeShellApplication {
    name = "stalwart-sieve-provision";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
      pkgs.coreutils
      pkgs.gnused
    ];
    text = builtins.readFile ./sieve-provision.sh;
  };
in
{
  options.custom.profiles.mail-sieve = {
    enable = lib.mkEnableOption ''
      a declaratively-managed per-user Sieve script on the Stalwart mailbox,
      converged over JMAP at activation. Enable on the mail host alongside
      custom.profiles.mail.

      Stalwart keeps per-user Sieve as ACCOUNT DATA, not configuration — there is
      no config-file equivalent — so this converges it through JMAP instead of
      declaring it in settings. Being a unit rather than a hand-edit is what makes
      it survive a wiped Stalwart database: activation re-asserts it.
    '';

    user = lib.mkOption {
      type = lib.types.str;
      example = "thomas";
      description = ''
        JMAP/Stalwart login (the principal name, not the email address) whose
        Sieve script this manages. Scripts are per-account, so this is also the
        only account the script affects.
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      default = config.sops.secrets.email_password.path;
      defaultText = lib.literalExpression "config.sops.secrets.email_password.path";
      description = ''
        File holding `user`'s JMAP password. The account's own credential is
        enough — no admin secret — because per-user Sieve is that account's data.
      '';
    };

    scriptName = lib.mkOption {
      type = lib.types.str;
      default = "default";
      description = ''
        Name the script is stored under in Stalwart. Stalwart activates one
        script per account, and this module manages exactly that one; renaming it
        leaves the old script behind, deactivated.
      '';
    };

    script = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = lib.literalExpression ''
        '''
          require ["imap4flags"];
          if header :contains "X-Forwarded-For" "someone@example.com" {
              addflag "forwarded";
          }
        '''
      '';
      description = ''
        Sieve source. Validated against the live server (SieveScript/validate)
        before it is activated, so a script that does not compile fails the unit
        instead of breaking delivery.

        Mind that Sieve's implicit `keep` still applies: a script that only sets
        flags does not change where mail is filed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = mailCfg.enable;
        message = "custom.profiles.mail-sieve requires custom.profiles.mail.enable (it provisions a script into that mail server over its loopback JMAP listener).";
      }
      {
        assertion = cfg.script != "";
        message = "custom.profiles.mail-sieve.script is empty — set a script, or disable the profile. Activating an empty script would silently replace whatever is there.";
      }
    ];

    systemd.services.mail-sieve-provision = {
      description = "Converge the ${cfg.user} per-user Sieve script into Stalwart (JMAP)";

      # Not start-rate-limited. systemd's default (5 starts per 10s) is there to
      # stop a crash-looping daemon and is wrong for an idempotent convergence
      # oneshot: an operator re-running this by hand to debug is normal, and
      # hitting the limit makes systemd refuse to start it at all until someone
      # runs `systemctl reset-failed`. Same rationale as the matrix provisioning
      # oneshots (ADR-0017 / the start-limit trap).
      startLimitIntervalSec = 0;

      after = [ "stalwart.service" ];
      wants = [ "stalwart.service" ];
      wantedBy = [ "multi-user.target" ];

      # Re-converge when the script itself changes; without this a rebuild that
      # only edits the Sieve would leave the old one active.
      restartTriggers = [ scriptFile ];

      environment = {
        JMAP_URL = jmapUrl;
        SIEVE_USER = cfg.user;
        SIEVE_NAME = cfg.scriptName;
        SIEVE_FILE = "${scriptFile}";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential = [ "account_password:${cfg.passwordFile}" ];
        ExecStart = lib.getExe provision;

        # Nothing here needs privilege beyond reading the credential systemd
        # hands it, and it only ever talks to loopback.
        DynamicUser = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };
  };
}
