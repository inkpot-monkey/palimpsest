# Navidrome — the friends' shared music platform (ADR-0027). A host-agnostic profile,
# enabled with `custom.profiles.navidrome.enable = true` (rk1b, the media node).
#
# One shared communal library at /var/cache/music; every friend gets their own account
# (favourites/playlists/history). Friends listen through the Subsonic client ecosystem
# (Amperfy on iOS, Symfonium on Android) or the web player. There is no self-signup by
# design — the `admin` user is bootstrapped declaratively from a sops secret (below), and
# friend accounts are provisioned declaratively too via `provisionUsers` (the sops `users`
# map, driven through Navidrome's native API) or still hand-created in the admin UI.
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
  pkgs,
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
    provisionUsers = lib.mkEnableOption ''
      a post-start oneshot that ensures a Navidrome account exists for every entry in the
      sops `users` map (profiles/navidrome.yaml, `username: password`). Navidrome has no
      declarative user provisioning — this drives its native REST API (navidrome-provision-users.py).
      Idempotent + create-only (a password later changed in the UI is never clobbered), and
      fail-loud. Adding a friend is then: add to the secret, redeploy'';
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
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
      }

      # Opt-in declarative user provisioning. Navidrome bootstraps only the `admin` account (via
      # ND_DEVAUTOCREATEADMINPASSWORD above); every other account is otherwise hand-made in the
      # admin UI. This oneshot codifies that for the sops `users` map — same shape as the HA voice
      # provisioner — so accounts survive a DB wipe and adding a friend is a secret edit + redeploy.
      (lib.mkIf cfg.provisionUsers {
        # sops-nix can only extract a SCALAR string value (its recurseSecretKey ends in a
        # `.(string)` assertion), so `key = "users"` on the YAML map would make sops-install-secrets
        # fail and install NOTHING. Instead take the whole decrypted file (`key = ""`) and let the
        # ExecStart wrapper `yq` the `users` map out to JSON — the user's secret stays a clean YAML map.
        sops.secrets.navidrome_secrets_bundle = {
          sopsFile = self.lib.getSecretFile "navidrome";
          key = "";
        };

        systemd.services.navidrome-provision-users = {
          description = "Provision Navidrome accounts from the sops users map";
          after = [ "navidrome.service" ];
          requires = [ "navidrome.service" ];
          wantedBy = [ "multi-user.target" ];
          unitConfig.RequiresMountsFor = [ "/var/cache" ];
          environment.ND_URL = "http://127.0.0.1:${toString svc.port}";
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            # Secrets land in a per-service tmpfs (CREDENTIALS_DIRECTORY), never argv/environ; the
            # extracted users JSON is written to the unit's private RuntimeDirectory (0700, root).
            RuntimeDirectory = "navidrome-provision-users";
            RuntimeDirectoryMode = "0700";
            LoadCredential = [
              "admin_password:${config.sops.secrets.navidrome_admin_password.path}"
              "bundle:${config.sops.secrets.navidrome_secrets_bundle.path}"
            ];
            ExecStart = pkgs.writeShellScript "navidrome-provision-users" ''
              set -euo pipefail
              ${pkgs.yq-go}/bin/yq -o=json '.users // {}' \
                "$CREDENTIALS_DIRECTORY/bundle" > "$RUNTIME_DIRECTORY/users.json"
              export ND_ADMIN_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/admin_password"
              export ND_USERS_FILE="$RUNTIME_DIRECTORY/users.json"
              exec ${pkgs.python3}/bin/python3 ${./navidrome-provision-users.py}
            '';
          };
        };
      })
    ]
  );
}
