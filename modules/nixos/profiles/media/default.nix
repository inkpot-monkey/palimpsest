{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.media;

in
{
  imports = [
    ./qbittorrent.nix
    ./jellyfin.nix
    ./slskd.nix
  ];

  options.custom.profiles.media = {
    enable = lib.mkEnableOption "Media server and automation configuration";
    mediaPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/media";
      description = "The base path for media storage.";
    };
    testMode = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable test mode (mock secrets).";
    };
  };

  config = lib.mkIf cfg.enable {
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

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
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
