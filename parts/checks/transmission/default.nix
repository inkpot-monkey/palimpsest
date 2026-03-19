{
  self,
  pkgs,
  ...
}:

let
  # Pre-fetch OCI images for the test
  gluetunImage = pkgs.dockerTools.pullImage {
    imageName = "qmcgaw/gluetun";
    imageDigest = "sha256:fcbe2e4919b05dd9653a6ce64304bd4f532d5b52e1356aaec4430713fa53c839";
    hash = "sha256-xn4e5M7YhoLAt/yKR+WArE25mn7xbNrG9NunIBHNtHM=";
    finalImageTag = "latest";
  };

  transmissionImage = pkgs.dockerTools.pullImage {
    imageName = "lscr.io/linuxserver/transmission";
    imageDigest = "sha256:bd9d4858be1138787cd3e4d05d2f8be72ab24685117361f47184f95d9215d859";
    hash = "sha256-30Esrj+TtBH4V48ZwRSAAPUnHuqansN1/FfqWDVqA9M=";
    finalImageTag = "latest";
  };
in
pkgs.testers.nixosTest {
  name = "transmission-vpn-test";

  nodes = {
    # 1. Mock VPN Gateway (Wireguard Server)
    server =
      { pkgs, ... }:
      {
        networking = {
          firewall.allowedUDPPorts = [ 51820 ];
          interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.1";
              prefixLength = 24;
            }
          ];
          wireguard.interfaces.wg0 = {
            ips = [ "10.0.0.1/24" ];
            listenPort = 51820;
            # Server Private Key
            privateKey = "eDM04sbQuX+DYTaHQ5MwP1Y6LwY3fZhVxTjHEOrnd3I=";
            peers = [
              {
                # Client Public Key
                publicKey = "yP7pm128eOd0DVzQlM4JL7gc889ThPI5FcTsOxgrZBA=";
                allowedIPs = [ "10.0.0.2/32" ];
              }
            ];
          };
          firewall.enable = false;
        };
        boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
        # Mock "Internet" interface (listen on tunnel IP)
        systemd.services.mock-internet = {
          description = "Mock Internet Server";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 -m http.server 80";
            WorkingDirectory = pkgs.writeTextDir "index.html" "VPN_CONNECTED";
          };
        };
        networking.firewall.allowedTCPPorts = [ 80 ];
      };

    # 2. Transmission Client
    client =
      { lib, ... }:
      {
        imports = [
          ../../../modules/nixos/profiles/podman.nix
          ../../../modules/nixos/profiles/media/transmission.nix
        ];

        options = {
          custom.profiles = {
            impermanence.enable = lib.mkEnableOption "mock";
            sops.enable = lib.mkEnableOption "mock";
          };
          environment.persistence = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
          sops = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
        };

        config = {
          _module.args = {
            inherit self;
            settings = {
              services.private.torrent.port = 9091;
            };
          };

          # Increase RAM for Podman containers
          virtualisation.memorySize = 2048;
          networking.firewall.enable = false;

          custom.profiles.transmission = {
            enable = true;
            testMode = true;
            gluetunImage = "qmcgaw/gluetun:latest";
            transmissionImage = "lscr.io/linuxserver/transmission:latest";
          };

          networking.interfaces.eth1.ipv4.addresses = [
            {
              address = "192.168.1.2";
              prefixLength = 24;
            }
          ];

          # Use environment variables instead of files for Gluetun
          virtualisation.oci-containers.containers.gluetun.environment = {
            VPN_SERVICE_PROVIDER = "custom";
            VPN_TYPE = "wireguard";
            WIREGUARD_PRIVATE_KEY = "yGF3ioDzQgqeIxtxx/h2Ut1XsGEXXNJGwkoLW3DUkV4=";
            WIREGUARD_ADDRESSES = "10.0.0.2/32";
            WIREGUARD_PUBLIC_KEY = "bRBH6Ol9p/6SvrMKN2s3W2uJE4H5E9ZG1g3f9Dil4C4="; # Server Public Key
            WIREGUARD_ENDPOINT_IP = "192.168.1.1";
            WIREGUARD_ENDPOINT_PORT = "51820";
            WIREGUARD_LAN_ADDRESSES = "192.168.1.0/24";
            DOT = "off";
            BLOCK_MALICIOUS = "off";
            HEALTH_ENABLED = "off";
            DNS_KEEP_NAMESERVER = "on";
            MTU_DISCOVERY = "off";
            LOG_LEVEL = "debug";
            WIREGUARD_IMPLEMENTATION = "software";
          };
        };
      };
  };

  testScript = ''
    start_all()

    # Stop services to prevent premature start (race condition)
    client.execute("systemctl stop podman-gluetun.service podman-transmission.service")

    # Preload OCI images into client
    client.succeed("podman load -i ${gluetunImage}")
    client.succeed("podman load -i ${transmissionImage}")

    # Start services now that images are loaded
    client.succeed("systemctl start podman-gluetun.service")
    client.wait_for_unit("podman-gluetun.service")
    client.succeed("systemctl start podman-transmission.service")
    client.wait_for_unit("podman-transmission.service")

    # 1. Verify successful VPN routing
    # Trigger handshake from both sides
    server.execute("ping -c 1 10.0.0.2")
    # Wait for the tunnel to actually be up and routing
    client.wait_until_succeeds("podman exec transmission curl -s -f http://10.0.0.1")
    client.succeed("podman exec transmission curl -s http://10.0.0.1 | grep VPN_CONNECTED")

    # 2. Verify Killswitch (Stop VPN Server listener)
    server.succeed("systemctl stop mock-internet")
    # Transmission should fail to reach the server (connection refused/timeout)
    client.fail("podman exec transmission curl -s --max-time 5 http://10.0.0.1")

    # 3. Verify Killswitch (Stop Gluetun Container)
    client.succeed("systemctl stop podman-gluetun.service")
    # Transmission container might be stopped or network-less. 
    # Attempting to exec or connect should fail.
    client.fail("podman exec transmission curl -s --max-time 5 http://10.0.0.1")
  '';
}
