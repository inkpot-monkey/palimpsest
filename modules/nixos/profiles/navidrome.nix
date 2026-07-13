# Navidrome — the friends' shared music platform (ADR-0027). A host-agnostic profile,
# enabled with `custom.profiles.navidrome.enable = true` (rk1b, the media node).
#
# One shared communal library at /var/cache/music; every friend gets their own account
# (favourites/playlists/history). Friends listen through the Subsonic client ecosystem
# (Amperfy on iOS, Symfonium on Android) or the web player. There is no self-signup by
# design — the `admin` user is bootstrapped declaratively from a sops secret (below) and
# friend accounts are hand-created in the admin UI.
#
# Access is tailnet-only: Navidrome binds all interfaces but the firewall opens its port
# only on `tailscale0`, and kelpy's Caddy fronts it at music.<domain> under internal_only
# (see modules/nixos/profiles/proxy.nix + the `music` entry in parts/settings.nix). The
# origin=rk1b service is reached by kelpy's Caddy over tailscale, so it can NOT bind
# loopback-only — same pattern as Home Assistant (homeassistant.nix).
#
# Library + DB live on the NVMe /var/cache subtree, which is a real block-device mount
# (hosts/rk1/nvme.nix) — durable across the tmpfs-root reboot with no impermanence entry.
{
  config,
  lib,
  self,
  settings,
  ...
}:
let
  cfg = config.custom.profiles.navidrome;
  # Endpoint metadata comes from the `music` service entry in settings: the port it
  # listens on, and the edge host where Caddy fronts it at music.<domain>.
  svc = settings.services.private.music;
in
{
  options.custom.profiles.navidrome = {
    enable = lib.mkEnableOption "Navidrome music server (the friends' shared library)";
  };

  config = lib.mkIf cfg.enable {
    services.navidrome = {
      enable = true;
      settings = {
        # Bind all interfaces (not the module default 127.0.0.1): kelpy's Caddy reaches
        # this over tailscale. The tailscale0-only firewall rule below is what keeps it
        # off the public LAN; Caddy's internal_only guard is the second layer.
        Address = "0.0.0.0";
        Port = svc.port;
        # The single shared library + its DB/cache on the durable NVMe /var/cache subtree.
        MusicFolder = "/var/cache/music";
        DataFolder = "/var/cache/navidrome";
        CacheFolder = "/var/cache/navidrome/cache";
        # inotify library watcher: new files appear without a manual scan.
        Scanner.WatcherEnabled = true;
        # No anonymous usage telemetry.
        EnableInsightsCollector = false;
      };
      # Bootstrap the `admin` user on first run without leaking the password into the
      # world-readable Nix store: ND_DEVAUTOCREATEADMINPASSWORD is rendered into an env
      # file from the sops secret (systemd reads EnvironmentFile as root before dropping
      # to the navidrome user). Friends are created on demand in the admin UI.
      environmentFile = config.sops.templates."navidrome-env".path;
    };

    sops.secrets.navidrome_admin_password.sopsFile = self.lib.getSecretFile "navidrome";
    sops.templates."navidrome-env".content = ''
      ND_DEVAUTOCREATEADMINPASSWORD=${config.sops.placeholder.navidrome_admin_password}
    '';

    # Gate startup on the NVMe /var/cache mount so a missing/un-fitted drive can't strand
    # the DB/library on the tmpfs root or refill the 29 GB eMMC. RequiresMountsFor is the
    # mechanism hosts/rk1/nvme.nix's header calls for; it generates the Requires=/After=
    # ordering on var-cache.mount itself.
    systemd.services.navidrome.unitConfig.RequiresMountsFor = [ "/var/cache" ];

    # Tailnet-only: friends join tailscale to listen; kelpy's Caddy proxies in over it.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ svc.port ];
  };
}
