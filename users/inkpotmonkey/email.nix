{
  config,
  pkgs,
  lib,
  ...
}:

let
  protonEmail = "your.email@proton.me";
  gmailEmail = "thomas@yeesshh.com";
  myName = "Your Name";
in
{

  # ============================================================================
  # 1. SOPS SECRETS
  # ============================================================================
  sops.secrets."proton_bridge/password" = {
    sopsFile = ./secrets.yaml;
    format = "yaml";
  };

  sops.secrets."gmail/password" = {
    sopsFile = ./secrets.yaml;
    format = "yaml";
  };

  # ============================================================================
  # 2. PACKAGES & SERVICES
  # ============================================================================
  home.packages = with pkgs; [
    protonmail-bridge
    isync
    notmuch
    coreutils
  ];

  # Keep your existing Proton Bridge Service config here...
  systemd.user.services.protonmail-bridge = {
    # ... (same as before) ...
    Unit.Description = "ProtonMail Bridge";
    Service.ExecStart = "${pkgs.protonmail-bridge}/bin/protonmail-bridge --noninteractive --log-level info";
    Service.Environment = "PATH=${pkgs.gnome-keyring}/bin:$PATH";
    Install.WantedBy = [ "default.target" ];
  };

  # ============================================================================
  # 3. EMAIL ACCOUNTS
  # ============================================================================

  programs.mbsync.enable = true;

  # Update Notmuch to handle two accounts
  programs.notmuch = {
    enable = true;
    hooks = {
      preNew = "${pkgs.isync}/bin/mbsync --all";
      # Tagging strategy:
      # 1. Tag everything new as 'new'
      # 2. If it's in the proton folder, add 'proton' tag
      # 3. If it's in the gmail folder, add 'gmail' tag
      postNew = ''
        ${pkgs.notmuch}/bin/notmuch tag +proton -new -- tag:new and path:proton/**
        ${pkgs.notmuch}/bin/notmuch tag +gmail -new  -- tag:new and path:gmail/**
      '';
    };
  };

  accounts.email = {
    maildirBasePath = "Mail";

    # --- ACCOUNT 1: PROTON ---
    accounts.proton = {
      primary = true;
      address = protonEmail;
      realName = myName;
      userName = protonEmail;
      imap.host = "127.0.0.1";
      imap.port = 1143;
      imap.tls.enable = false;
      smtp.host = "127.0.0.1";
      smtp.port = 1025;
      smtp.tls.enable = false;
      passwordCommand = "${pkgs.coreutils}/bin/cat ${
        config.sops.secrets."proton_bridge/password".path
      } | ${pkgs.coreutils}/bin/tr -d '\n'";

      mbsync = {
        enable = true;
        create = "both";
        expunge = "both";
        patterns = [ "*" ];
      };
      notmuch.enable = true;
    };

    # --- ACCOUNT 2: GMAIL ---
    accounts.gmail = {
      address = gmailEmail;
      realName = myName;
      userName = gmailEmail; # Gmail username is full email
      flavor = "gmail.com"; # Helper that sets IMAP/SMTP hosts automatically

      # We override passwordCommand to use the Gmail secret
      passwordCommand = "${pkgs.coreutils}/bin/cat ${
        config.sops.secrets."gmail/password".path
      } | ${pkgs.coreutils}/bin/tr -d '\n'";

      # Custom mbsync settings for Gmail folders
      mbsync = {
        enable = true;
        create = "both";
        expunge = "both";
        remove = "both";

        # This map is CRITICAL for Gmail to look normal
        groups.gmail = {
          channels = {
            inbox = {
              farPattern = "INBOX";
              nearPattern = "Inbox";
            };
            sent = {
              farPattern = "[Gmail]/Sent Mail";
              nearPattern = "Sent";
            };
            trash = {
              farPattern = "[Gmail]/Trash";
              nearPattern = "Trash";
            };
            drafts = {
              farPattern = "[Gmail]/Drafts";
              nearPattern = "Drafts";
            };
            # Optional: Sync everything else (Archives/Labels)
            # Warning: "All Mail" is huge. Many people skip it to save space.
            # If you want it, uncomment below:
            # all = {
            #   farPattern = "[Gmail]/All Mail";
            #   nearPattern = "Archive";
            # };
          };
        };
      };

      notmuch.enable = true;
    };
  };

  # ============================================================================
  # 4. EMACS PACKAGES
  # ============================================================================
  # programs.emacs.extraPackages = epkgs: [
  # epkgs.notmuch
  # epkgs.consult-notmuch
  # epkgs.auth-source-sops
  # ];
}
