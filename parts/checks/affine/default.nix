{
  self,
  pkgs,
  inputs,
  ...
}:

pkgs.testers.nixosTest {
  name = "affine-podman-test";

  nodes.machine =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.impermanence.nixosModules.impermanence
        inputs.sops-nix.nixosModules.sops

        (self + /modules/nixos/profiles/podman.nix)
        (self + /modules/nixos/profiles/affine)
      ];

      config = {
        # Provide dummy settings for the profile
        _module.args.settings = {
          admin.email = "test@example.com";
        };

        # Satisfy sops assertion
        sops.age.keyFile = "/etc/dummy-sops-key";
        sops.defaultSopsFile = pkgs.writeText "dummy-sops.yaml" "";
        sops.validateSopsFiles = false;

        # Provide a dummy domain for Caddy
        networking.domain = "local";

        # 1. Bypass SOPS for the sandbox environment
        sops.secrets.affine_password.path = lib.mkForce "/etc/mock-db-password";
        sops.templates."affine-env".path = lib.mkForce "/etc/mock-affine-env";

        environment.etc."mock-db-password".text = "testpassword123";
        environment.etc."mock-affine-env".text = ''
          DATABASE_URL=postgresql://affine:testpassword123@10.88.0.1:5432/affine
          AFFINE_SERVER_EXTERNAL_URL=http://affine.local
          REDIS_SERVER_HOST=10.88.0.1
          REDIS_SERVER_PORT=6379
        '';

        # 2. Local DNS resolution so Caddy can route the request
        networking.hosts."127.0.0.1" = [ "affine.local" ];

        # 3. Simplify Caddy to remove your custom imports for the test
        services.caddy.enable = true;
        services.caddy.extraConfig = ''
          (internal_only) {
          }
          (cloudflare_tls) {
          }
        '';

        systemd.services.affine-migration.script = lib.mkForce "echo 'Migration mocked'";

        services.caddy.virtualHosts."http://affine.local" = lib.mkForce {
          extraConfig = ''
            reverse_proxy 127.0.0.1:3010
          '';
        };

        # 4. Mock the OCI container to avoid needing internet access to docker pull
        # We use a tiny python web server to prove the port bindings and networking work.
        virtualisation.oci-containers.backend = "podman";
        virtualisation.oci-containers.containers.affine = lib.mkForce {
          # Use a dummy busybox image that NixOS can build offline
          image = "ghcr.io/toeverything/affine:stable";
          imageFile = pkgs.dockerTools.buildImage {
            name = "localhost/busybox";
            tag = "latest";
            copyToRoot = [ pkgs.python3 ];
            config.Cmd = [
              "python3"
              "-m"
              "http.server"
              "3010"
            ];
          };
          ports = [ "127.0.0.1:3010:3010" ];
        };
      };
    };

  testScript = ''
    machine.start()

    # 1. Wait for databases
    machine.wait_for_unit("postgresql.service")
    machine.wait_for_unit("redis-affine.service")

    # Verify the Podman gateway bindings
    machine.wait_for_open_port(5432)
    # Redis is bound to 10.88.0.1, so we check that specifically if possible, 
    # or just wait for the port to be open on the machine.
    machine.wait_for_open_port(6379)

    # 2. Wait for the mocked container
    machine.wait_for_unit("podman-affine.service")
    machine.wait_for_open_port(3010)

    # 3. Wait for Caddy
    machine.wait_for_unit("caddy.service")

    # 4. Verify the entire chain: Host -> Caddy -> Podman Container
    response = machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://affine.local")

    # Python returns 200, proving Caddy successfully routed the traffic to the container
    assert response == "200", f"Expected 200 OK via Caddy, got: {response}"
  '';
}
