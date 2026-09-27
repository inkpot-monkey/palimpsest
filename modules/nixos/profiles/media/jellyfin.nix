{
  config,
  lib,
  ...
}:

let
  cfg = config.custom.profiles.media;
in
{
  config = lib.mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      # NOT openFirewall: that opens 8096 on every interface, which off-edge would
      # mean the home LAN as well as the tailnet. media/default.nix opens the port
      # on tailscale0 alone when this stack runs off the Caddy edge; on the edge
      # Caddy reaches it over loopback and nothing needs opening at all.
      openFirewall = false;
    };

    # Jellyfin needs access to the 'users' group to read Transmission downloads
    users.users.jellyfin.extraGroups = [
      "render"
      "users"
    ];

    systemd.tmpfiles.rules = [
      "Z /var/cache/jellyfin 0750 jellyfin jellyfin - -"
      "Z /var/lib/jellyfin 0700 jellyfin jellyfin - -"
    ];

    # /var/lib/jellyfin always needs persisting on an impermanent host. /var/cache/jellyfin
    # only does when /var/cache is part of the impermanent root — on a host that mounts it
    # as its own durable filesystem (the rk1 nodes' NVMe) the cache is already durable, and
    # listing it here fails eval outright: impermanence requires the underlying filesystem
    # to be neededForBoot, which a data mount is not.
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/jellyfin";
          user = "jellyfin";
          group = "media";
          mode = "0750";
        }
      ]
      ++ lib.optional (!(config.fileSystems ? "/var/cache")) {
        directory = "/var/cache/jellyfin";
        user = "jellyfin";
        group = "media";
        mode = "0750";
      };
    };
  };
}
