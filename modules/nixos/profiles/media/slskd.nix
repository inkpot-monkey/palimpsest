{
  config,
  lib,
  settings,
  self,
  ...
}:

let
  cfg = config.custom.profiles.media;
  inherit (cfg) slskd;

  # Reproducible OCI image, digest-pinned like gluetun/qbittorrent in ./qbittorrent.nix.
  # slskd 0.26.0.0.
  slskdImage = "slskd/slskd@sha256:ecd4026d4f8fb504e2cc55323efa2c1f5b56d20d3686b018249cc36b48ea17a6";

  # The web UI port is the service-registry port (kept as one source of truth so Caddy's
  # upstream and slskd's listener never drift); published to loopback for Caddy to front.
  webPort = settings.services.private.slskd.port;
  # slskd's default Soulseek listen port. Not a host-tunable option: it lives entirely
  # inside gluetun's netns and is never published, so nothing external can consume a
  # tuned value (ADR-0029 — no inbound port on the host).
  listenPort = 50300;

  # The git-annex repos on this host that own the path slskd is told to share.
  libraryRepos = lib.filter (r: r.path == slskd.libraryPath) (
    lib.attrValues config.services.git-annex.repositories
  );
in
{
  options.custom.profiles.media.slskd = {
    enable = lib.mkEnableOption "slskd, seeding the music library on Soulseek through the VPN";

    libraryPath = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/git-annex/music";
      description = ''
        The music library slskd shares on Soulseek, mounted read-only. Defaults to
        kelpy's git-annex `music` replica (ADR-0028): a full, `unlock`+`thin` copy of
        rk1b's authoritative library, so slskd reads real bytes rather than symlinks
        into `.git/annex/objects`. Read-only is load-bearing — a write here would mutate
        the shared annex object behind a `thin` hardlink and corrupt the replica.
      '';
    };
  };

  # slskd requires the VPN + podman that the media profile's qbittorrent half already
  # brings up (./qbittorrent.nix, unconditional under media.enable), so it is gated on
  # BOTH media.enable and its own toggle. That is also why nothing here re-enables
  # podman or redefines the gluetun container — it only appends to them.
  config = lib.mkIf (cfg.enable && slskd.enable) {
    # Fail loud rather than seed a broken tree. slskd's whole purpose is sharing the
    # replica, so the path it mounts must (1) be a declared annex repo, and (2) be
    # `unlock`+`thin` — an un-unlocked repo is a tree of symlinks into
    # `.git/annex/objects`, which slskd would share as dangling links, not real bytes.
    assertions = [
      {
        assertion = libraryRepos != [ ];
        message = ''
          custom.profiles.media.slskd shares ${slskd.libraryPath}, but no
          services.git-annex.repositories entry owns that path — slskd would seed a
          missing or empty tree. Enable the git-annex `music` replica on this host
          (ADR-0028) or point slskd.libraryPath at the repo that holds the library.
        '';
      }
      {
        assertion = lib.all (r: r.unlock && r.thin) libraryRepos;
        message = ''
          custom.profiles.media.slskd shares ${slskd.libraryPath}, but that git-annex
          repo is not `unlock` + `thin`. slskd must read real file bytes to seed them;
          a locked repo is symlinks into .git/annex/objects that it would share as
          dangling links. Set unlock = true; thin = true; on the repository (ADR-0028).
        '';
      }
    ];

    # slskd's own state (share database, generated slskd.yml, transfer history). Kept
    # deliberately OUT of the library tree; the container runs as root, so 0700 root.
    systemd.tmpfiles.rules = [
      "d /var/lib/slskd 0700 root root - -"
      "d ${cfg.mediaPath}/slskd-downloads 2775 root media - -"
      "d ${cfg.mediaPath}/slskd-downloads/incomplete 2775 root media - -"
    ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        {
          directory = "/var/lib/slskd";
          user = "root";
          group = "root";
          mode = "0700";
        }
      ];
    };

    # Credentials live as nested keys in profiles/media.yaml (slskd.slsk.username, etc.)
    # and are assembled into the env file slskd sources — never written to the
    # world-readable nix store. sops-template pattern, as in the proxy profile's caddy_env.
    sops.secrets = lib.mkIf (!cfg.testMode) {
      "slskd/slsk/username" = {
        sopsFile = self.lib.getSecretFile "media";
      };
      "slskd/slsk/password" = {
        sopsFile = self.lib.getSecretFile "media";
      };
      "slskd/username" = {
        sopsFile = self.lib.getSecretFile "media";
      };
      "slskd/password" = {
        sopsFile = self.lib.getSecretFile "media";
      };
    };
    sops.templates.slskd_env = lib.mkIf (!cfg.testMode) {
      content = ''
        SLSKD_SLSK_USERNAME=${config.sops.placeholder."slskd/slsk/username"}
        SLSKD_SLSK_PASSWORD=${config.sops.placeholder."slskd/slsk/password"}
        SLSKD_USERNAME=${config.sops.placeholder."slskd/username"}
        SLSKD_PASSWORD=${config.sops.placeholder."slskd/password"}
      '';
    };

    # slskd shares the gluetun VPN container's network namespace, so every Soulseek
    # connection egresses through ProtonVPN exactly like qBittorrent — which is why its
    # web UI is PUBLISHED ON gluetun, not on the slskd container (a joined container has
    # no ports of its own). This `.ports` list merges with the list gluetun already
    # declares in ./qbittorrent.nix (list-typed options concatenate across modules).
    #
    # ONLY the web UI is published, and only to loopback (Caddy fronts it). The Soulseek
    # LISTEN port is deliberately NOT published on the host: slskd's traffic exits via the
    # VPN, so peers are told the VPN exit IP, never kelpy's public one — a host publish
    # would expose a port to the internet that no peer ever uses. Seeding still works
    # without an inbound port (Soulseek brokers indirect connections outbound when a
    # downloader can't reach us). Direct inbound would need ProtonVPN port forwarding
    # (gluetun VPN_PORT_FORWARDING) wired through to slskd — a future refinement.
    virtualisation.oci-containers.containers.gluetun.ports = [
      "127.0.0.1:${toString webPort}:${toString webPort}/tcp"
    ];

    virtualisation.oci-containers.containers.slskd = {
      image = slskdImage;
      dependsOn = [ "gluetun" ];
      extraOptions = [
        "--network=container:gluetun"
        "--runtime=runc"
      ];
      # The rendered credentials env file (SLSKD_SLSK_USERNAME/PASSWORD for the Soulseek
      # account, SLSKD_USERNAME/PASSWORD for the web UI), assembled from the sops keys above.
      environmentFiles = lib.optional (!cfg.testMode) config.sops.templates.slskd_env.path;
      environment = {
        SLSKD_SHARED_DIR = "/music";
        SLSKD_DOWNLOADS_DIR = "/downloads";
        SLSKD_INCOMPLETE_DIR = "/downloads/incomplete";
        SLSKD_HTTP_PORT = toString webPort;
        SLSKD_SLSK_LISTEN_PORT = toString listenPort;
        SLSKD_NO_VERSION_CHECK = "true";
        # The config is owned by nix; never let the web UI rewrite it to disk.
        SLSKD_REMOTE_CONFIGURATION = "false";
      };
      volumes = [
        "/var/lib/slskd:/app"
        "${slskd.libraryPath}:/music:ro"
        "${cfg.mediaPath}/slskd-downloads:/downloads"
      ];
    };
  };
}
