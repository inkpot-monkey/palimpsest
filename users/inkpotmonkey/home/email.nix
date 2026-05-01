{
  config,
  pkgs,
  lib,
  self,
  ...
}:

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
        extraConfig =
          (self.lib.mkMbsyncAccount {
            name = "yeesshh";
            host = "imap.gmail.com";
            user = config.identity.gmail;
            passCmd = "${pkgs.coreutils}/bin/cat ${config.sops.secrets."email/yeesshh/password".path}";
            extraConfig = ''
              CertificateFile /etc/ssl/certs/ca-certificates.crt
              PipelineDepth 1
            '';
          })
          + ''
            IMAPStore yeesshh-remote
            Account yeesshh

            MaildirStore yeesshh-local
            Path ${config.home.homeDirectory}/mail/yeesshh/
            Inbox ${config.home.homeDirectory}/mail/yeesshh/Inbox
            SubFolders Verbatim
          ''
          + (self.lib.mkMbsyncChannel {
            name = "yeesshh-inbox";
            account = "yeesshh";
            far = "INBOX";
            near = "Inbox";
          })
          + (self.lib.mkMbsyncChannel {
            name = "yeesshh-sent";
            account = "yeesshh";
            far = "[Gmail]/Sent Mail";
            near = "Sent";
          })
          + (self.lib.mkMbsyncChannel {
            name = "yeesshh-trash";
            account = "yeesshh";
            far = "[Gmail]/Trash";
            near = "Trash";
          })
          + (self.lib.mkMbsyncChannel {
            name = "yeesshh-drafts";
            account = "yeesshh";
            far = "[Gmail]/Drafts";
            near = "Drafts";
          })
          + ''
            Group yeesshh
            Channel yeesshh-inbox
            Channel yeesshh-sent
            Channel yeesshh-trash
            Channel yeesshh-drafts
          ''
          + (self.lib.mkMbsyncAccount {
            name = "proton";
            host = "127.0.0.1";
            port = 1143;
            user = config.identity.email;
            passCmd = "${pkgs.coreutils}/bin/cat ${config.sops.secrets."email/protonmail/password".path}";
            tlsType = "None";
          })
          + ''
            IMAPStore proton-remote
            Account proton

            MaildirStore proton-local
            Path ${config.home.homeDirectory}/mail/proton/
            Inbox ${config.home.homeDirectory}/mail/proton/Inbox
            SubFolders Verbatim
          ''
          + (self.lib.mkMbsyncChannel {
            name = "proton";
            account = "proton";
            far = "";
            near = "";
            patterns = "*";
          })
          + ''
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
          address = config.identity.email;
          realName = config.identity.name;
          userName = config.identity.email;
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
          address = config.identity.gmail;
          realName = config.identity.name;
          userName = config.identity.gmail; # Gmail username is full email
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
