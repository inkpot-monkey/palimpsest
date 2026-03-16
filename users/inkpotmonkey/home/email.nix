{
  config,
  pkgs,
  lib,
  self,
  ...
}:

let
  protonEmail = "<SCRUBBED_EMAIL>";
  gmailEmail = "thomas@yeesshh.com";
  myName = "Thomas Kelly";
in
{
  options.custom.home.profiles.email = {
    enable = lib.mkEnableOption "email configuration (mbsync, notmuch, protonmail-bridge)";
  };

  config = lib.mkMerge [
    (lib.mkIf config.custom.home.profiles.email.enable {
      # ============================================================================
      # 1. SOPS SECRETS
      # ============================================================================
      sops.secrets."email/protonmail/password" = {
        sopsFile = self.lib.getUserSecretFile "inkpotmonkey";
        format = "yaml";
      };

      sops.secrets."email/yeesshh/password" = {
        sopsFile = self.lib.getUserSecretFile "inkpotmonkey";
        format = "yaml";
      };
      # ============================================================================
      # 2. PACKAGES & SERVICES
      # ============================================================================
      home.packages = with pkgs; [
        isync
        notmuch
        coreutils
        gcr # Prompter for unlocking keyring
      ];

      # Zero-touch setup: Ensure Maildir roots exist so mbsync doesn't crash
      home.activation.createMaildir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        $DRY_RUN_CMD mkdir -p ${config.home.homeDirectory}/mail/yeesshh ${config.home.homeDirectory}/mail/proton
      '';

      services.protonmail-bridge = {
        enable = true;
        logLevel = "info";
        extraPackages = [ pkgs.gnome-keyring ];
      };

      # The upstream module doesn't pass DBus address, which is critical for
      # communicating with the keyring daemon in our environment.
      systemd.user.services.protonmail-bridge.Service.PassEnvironment = [ "DBUS_SESSION_BUS_ADDRESS" ];

      services.imapnotify.enable = true;

      # ============================================================================
      # 3. EMAIL ACCOUNTS
      # ============================================================================

      programs.mbsync = {
        enable = true;
        extraConfig = ''
          # ========================================================================
          # MANUAL YEESSHH (GMAIL) CONFIGURATION
          # ========================================================================
          # We define this manually to avoid Home Manager module bugs/limitations.

          IMAPAccount yeesshh
          Host imap.gmail.com
          User ${gmailEmail}
          PassCmd "${pkgs.coreutils}/bin/cat ${config.sops.secrets."email/yeesshh/password".path}"
          AuthMechs LOGIN
          TLSType IMAPS
          CertificateFile /etc/ssl/certs/ca-certificates.crt
          PipelineDepth 1

          IMAPStore yeesshh-remote
          Account yeesshh

          MaildirStore yeesshh-local
          Path ${config.home.homeDirectory}/mail/yeesshh/
          Inbox ${config.home.homeDirectory}/mail/yeesshh/Inbox
          SubFolders Verbatim

          Channel yeesshh-inbox
          Far :yeesshh-remote:INBOX
          Near :yeesshh-local:Inbox
          Create Both
          Expunge Both
          Remove None

          Channel yeesshh-sent
          Far ":yeesshh-remote:[Gmail]/Sent Mail"
          Near :yeesshh-local:Sent
          Create Both
          Expunge Both
          Remove None

          Channel yeesshh-trash
          Far :yeesshh-remote:[Gmail]/Trash
          Near :yeesshh-local:Trash
          Create Both
          Expunge Both
          Remove None

          Channel yeesshh-drafts
          Far :yeesshh-remote:[Gmail]/Drafts
          Near :yeesshh-local:Drafts
          Create Both
          Expunge Both
          Remove None

          Group yeesshh
          Channel yeesshh-inbox
          Channel yeesshh-sent
          Channel yeesshh-trash
          Channel yeesshh-drafts

          # ========================================================================
          # MANUAL PROTON CONFIGURATION
          # ========================================================================
          IMAPAccount proton
          Host 127.0.0.1
          Port 1143
          User <SCRUBBED_EMAIL>
          PassCmd "${pkgs.coreutils}/bin/cat ${config.sops.secrets."email/protonmail/password".path}"
          AuthMechs LOGIN
          TLSType None

          IMAPStore proton-remote
          Account proton

          MaildirStore proton-local
          Path ${config.home.homeDirectory}/mail/proton/
          Inbox ${config.home.homeDirectory}/mail/proton/Inbox
          SubFolders Verbatim

          Channel proton
          Far :proton-remote:
          Near :proton-local:
          Patterns *
          Create Both
          Expunge Both
          Remove None
          SyncState *
        '';
      };

      # Update Notmuch to handle two accounts
      programs.notmuch = {
        enable = true;
        hooks = {
          preNew = "${pkgs.isync}/bin/mbsync --all";
          # Tagging strategy:
          # 1. Tag everything new as 'new'
          # 2. If it's in the proton folder, add 'proton' tag
          # 3. If it's in the yeesshh folder, add 'yeesshh' tag
          postNew = ''
            ${pkgs.notmuch}/bin/notmuch tag +proton -new -- tag:new and path:proton/**
            ${pkgs.notmuch}/bin/notmuch tag +yeesshh -new  -- tag:new and path:yeesshh/**
          '';
        };
      };

      accounts.email = {
        maildirBasePath = "mail";

        # --- ACCOUNT 1: PROTON ---
        accounts.proton = {
          primary = true;
          address = protonEmail;
          realName = myName;
          userName = "<SCRUBBED_EMAIL>";
          imap.host = "127.0.0.1";
          imap.port = 1143;
          imap.tls.enable = false;
          smtp.host = "127.0.0.1";
          smtp.port = 1025;
          smtp.tls.enable = false;
          passwordCommand = "${pkgs.coreutils}/bin/cat ${
            config.sops.secrets."email/protonmail/password".path
          }";

          # We disable local mbsync generation to handle it manually in global config
          mbsync.enable = false;
          notmuch.enable = true;
        };

        # --- ACCOUNT 2: YEESSHH (GMAIL) ---
        accounts.yeesshh = {
          address = gmailEmail;
          realName = myName;
          userName = gmailEmail; # Gmail username is full email
          flavor = "gmail.com"; # Helper that sets IMAP/SMTP hosts automatically

          # We override passwordCommand to use the Gmail secret
          passwordCommand = "${pkgs.coreutils}/bin/cat ${config.sops.secrets."email/yeesshh/password".path}";

          # We disable local mbsync generation to handle it manually in global config
          # This bypasses the Home Manager module type constraints and bugs.
          mbsync.enable = false;

          notmuch.enable = true;
        };
      };
    })
  ];
}
