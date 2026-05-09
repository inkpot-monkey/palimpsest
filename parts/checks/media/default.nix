{
  self,
  pkgs,
  inputs,
  ...
}:

pkgs.testers.nixosTest {
  name = "media-test";

  nodes = {
    client =
      { ... }:
      {
        _module.args = {
          inherit self inputs;
          settings = {
            services.private.torrent.port = 8080;
          };
        };
        imports = [
          self.nixosProfiles.media
          self.nixosProfiles.podman
          inputs.sops-nix.nixosModules.sops
          inputs.impermanence.nixosModules.impermanence
          (
            { lib, ... }:
            {
              options.custom.profiles.impermanence.enable = lib.mkEnableOption "dummy";
              config.custom.profiles.impermanence.enable = lib.mkForce false;
            }
          )
        ];

        custom.profiles.media = {
          enable = true;
          testMode = true;
        };

        # Mock SOPS for the test
        sops.gnupg.home = "/var/lib/sops";
        sops.defaultSopsFile = ./dummy.yaml;
        sops.secrets.qbittorrent = { };

        # Disable nix-command/flakes in the VM
        nix.settings.experimental-features = pkgs.lib.mkForce [ ];

        # Increased memory for the VM
        virtualisation.memorySize = 2048;

        # --- Simulate a realistic environment ---
        # Create transmission-like download directory with mock media files
        # so we can test the full permission chain: transmission -> media dir -> jellyfin
        systemd.services.mock-media-files = {
          description = "Create mock media files for testing";
          before = [ "flexget.service" ];
          wantedBy = [ "flexget.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            # Simulate qBittorrent's download directory structure
            mkdir -p /var/lib/media/downloads
            chmod 755 /var/lib/media
            chmod 755 /var/lib/media/downloads

            # Create a mock movie file (single file torrent)
            echo "MOCK_MOVIE_FILE" > /var/lib/media/downloads/The_Matrix_1999_1080p.mkv

            # Create a mock series season pack (multi-file torrent directory)
            mkdir -p "/var/lib/media/downloads/Test Series S01 (1080p)"
            for i in 01 02 03; do
              echo "MOCK_TV_FILE" > "/var/lib/media/downloads/Test Series S01 (1080p)/Test Series - S01E$i - Episode $i.mkv"
            done

            # Create a mock series single episode with [Cap.NNN] naming
            echo "MOCK_EPISODE_FILE" > /var/lib/media/downloads/Los Anos Nuevos [HDTV][Cap.101](wolfmax4k.com).avi

            # Set permissions to simulate qBittorrent container (PUID/PGID or just media group)
            # We use media group to ensure services can read it
            chown -R root:media /var/lib/media/downloads
            chmod -R 775 /var/lib/media/downloads

            echo "Mock media files created"
          '';
        };
      };
  };

  testScript = ''
    client.start()

    # ============================================================
    # 1. CORE SERVICES
    # ============================================================

    client.wait_for_unit("jellyfin.service")
    client.wait_for_open_port(8096)

    client.wait_for_unit("prowlarr.service")
    client.wait_for_open_port(9696)

    client.wait_for_unit("radarr.service")
    client.wait_for_open_port(7878)

    client.wait_for_unit("sonarr.service")
    client.wait_for_open_port(8989)

    # Verify directories ownership
    client.succeed("ls -ld /var/lib/jellyfin | grep jellyfin")
    client.succeed("ls -ld /var/lib/radarr | grep radarr")
    client.succeed("ls -ld /var/lib/sonarr | grep sonarr")

    # ============================================================
    # 2. PERMISSIONS: Services must be able to read downloads
    # ============================================================

    # Wait for mock media to be created
    client.wait_for_file(
      "/var/lib/media/downloads/The_Matrix_1999_1080p.mkv"
    )

    # Jellyfin must be able to read the downloads (via group)
    client.succeed(
      "sudo -u jellyfin ls -la /var/lib/media/downloads/"
    )
    client.succeed(
      "sudo -u jellyfin stat "
      "/var/lib/media/downloads/The_Matrix_1999_1080p.mkv"
    )

    # Radarr/Sonarr must be able to read/write in downloads
    client.succeed(
      "sudo -u radarr ls -la /var/lib/media/downloads/"
    )
    client.succeed(
      "sudo -u sonarr ls -la /var/lib/media/downloads/"
    )

    # ============================================================
    # 3. JELLYFIN API HEALTH CHECK
    # ============================================================

    client.succeed("curl -sf http://127.0.0.1:8096/health")
  '';
}
