{
  config,
  lib,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.media;

  # The whole profile moves as one unit, so one answer covers all three web UIs:
  # when the registry says this stack runs off the Caddy edge, the container ports
  # have to be published somewhere the edge can actually reach over the tailnet
  # instead of loopback. Read off `torrent` as the profile's representative entry —
  # jellyfin/slskd move with it by construction.
  offEdge = (settings.services.private.torrent.origin or null) == config.networking.hostName;
in
{
  imports = [
    ./qbittorrent.nix
    ./qbittorrent-port-forward.nix
    ./qbittorrent-preferences.nix
    ./gluetun-watchdog.nix
    ./jellyfin.nix
    ./slskd.nix
  ];

  options.custom.profiles.media = {
    enable = lib.mkEnableOption "Media server and automation configuration";
    mediaPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/media";
      example = "/var/cache/media";
      description = ''
        The base path for media storage.

        Override it on a host whose root is a tmpfs: the default lands on the
        impermanent root, which on the rk1 nodes is a 2G ramdisk that downloads
        fill immediately. Those hosts keep bulk data on the NVMe `/var/cache`
        subtree, as Navidrome and Stump do.
      '';
    };

    # Internal, not for hosts to set: derived above so the two container port
    # publishes (qbittorrent.nix, slskd.nix) share one definition rather than
    # each re-deriving it and drifting.
    bindHost = lib.mkOption {
      type = lib.types.str;
      internal = true;
      readOnly = true;
      default = if offEdge then "0.0.0.0" else "127.0.0.1";
      description = "Address the media web UIs are published on.";
    };
    vpnSecretFile = lib.mkOption {
      type = lib.types.str;
      default = "media";
      example = "video";
      description = ''
        Which stash file holds THIS host's ProtonVPN WireGuard credential (the
        `protonvpn_env` key inside it).

        Per-host because the credential is per-host, and that is not cosmetic: a
        WireGuard peer identity IS its public key, and ProtonVPN keeps ONE endpoint per
        key, repointing it on every authenticated handshake. Two hosts sharing a key flap
        each other's tunnel while both units stay green, and the NAT-PMP grant (ADR-0033)
        is per-session on that key too, so the forwarded port would be contended rather
        than owned (palimpsest#190).

        The files are therefore deliberately separate, each registered under its own name
        in the expiry registry — `protonvpn_env_kelpy` → profiles/media.yaml,
        `protonvpn_env_rk1b` → profiles/video.yaml. Set it where the host is declared;
        the module must not infer it, so that adding a third host is a stated fact rather
        than a branch somebody has to find.
      '';
    };

    jellyfin.provision = {
      enable = lib.mkEnableOption ''
        a post-start oneshot that completes Jellyfin's startup wizard and declares its
        libraries from this config (jellyfin-provision.py). Jellyfin has no declarative
        path for either: a fresh server sits at `StartupWizardCompleted: false` and
        serves nothing, and libraries are UI state thereafter. Idempotent and
        fail-loud, the same shape as custom.profiles.homeassistant.provision'';

      adminUser = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "Jellyfin admin account created by the wizard.";
      };

      uiCulture = lib.mkOption {
        type = lib.types.str;
        default = "en-GB";
        description = "Jellyfin UI culture.";
      };

      metadataCountry = lib.mkOption {
        type = lib.types.str;
        default = "GB";
        description = "Metadata country code.";
      };

      metadataLanguage = lib.mkOption {
        type = lib.types.str;
        default = "en";
        description = "Preferred metadata language.";
      };

      libraries = lib.mkOption {
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "Library name as it appears in Jellyfin.";
              };
              type = lib.mkOption {
                type = lib.types.str;
                example = "tvshows";
                description = "Jellyfin collection type (tvshows, movies, music, ...).";
              };
              path = lib.mkOption {
                type = lib.types.path;
                description = "Directory the library indexes.";
              };
            };
          }
        );
        default = [ ];
        description = ''
          Libraries to declare. Matched by NAME: an existing library is left alone
          rather than re-pointed, so renaming one here adds a second rather than
          moving the first.
        '';
      };
    };

    testMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable test mode (mock secrets).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Off-edge only, and on tailscale0 ALONE — never openFirewall, which would put
    # the torrent and Soulseek UIs on the home LAN. On the edge these stay on
    # loopback and the firewall is untouched.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = lib.mkIf offEdge [
      settings.services.private.torrent.port
      settings.services.private.slskd.port
      settings.services.public.jellyfin.port
    ];

    # Shared group for media access
    users.groups.media = {
      gid = 993;
    };

    # --- 2. Shared Directories ---
    systemd.tmpfiles.rules = [
      "d ${cfg.mediaPath} 2775 root media - -"
      "d ${cfg.mediaPath}/movies 2775 root media - -"
      "d ${cfg.mediaPath}/series 2775 root media - -"
      "d ${cfg.mediaPath}/tv 2775 root media - -"
      "d ${cfg.mediaPath}/downloads 2775 qbittorrent media - -"
    ];

    # Only when the tree actually sits under the impermanent root. Pointed at a durable
    # NVMe subtree (/var/cache on the rk1 nodes) it is already persistent, and naming it
    # here is worse than redundant: impermanence demands the underlying filesystem be
    # neededForBoot, which /var/cache is not, so the eval fails outright.
    environment.persistence."/persistent" =
      lib.mkIf (config.custom.profiles.impermanence.enable && lib.hasPrefix "/var/lib" cfg.mediaPath)
        {
          directories = [
            {
              directory = cfg.mediaPath;
              user = "root";
              group = "media";
              mode = "2775";
            }
          ];
        };
  };
}
