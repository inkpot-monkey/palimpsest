{
  self,
  pkgs,
  inputs,
  ...
}:

pkgs.testers.nixosTest {
  name = "flexget-webui-test";

  nodes.machine =
    { lib, ... }:
    {
      _module.args = {
        inherit inputs self;
      };
      imports = [
        self.nixosProfiles.media
        inputs.impermanence.nixosModules.impermanence
        inputs.sops-nix.nixosModules.sops
        (_: {
          options.custom.profiles.impermanence.enable = lib.mkEnableOption "dummy";
          config = {
            sops.validateSopsFiles = false;
            sops.defaultSopsFile = pkgs.writeText "dummy.yaml" "{}";
            sops.age.keyFile = "/tmp/dummy.age";
            custom.profiles.impermanence.enable = lib.mkForce false;
            # Force flexget on for the test
            custom.profiles.media = {
              enable = true;
              testMode = true;
            };

            # Provide mock password for the test
            sops.secrets.flexget_webui_password.path = "/tmp/flexget_password";
          };
        })
      ];

      # Ensure our overlay is applied locally for the test
      nixpkgs.overlays = [
        (import ../../../modules/shared/overlays/flexget.nix { inherit inputs; })
      ];

      # Mock SOPS secret for the test
      sops.secrets.flexget_webui_password = {
        # Using a dummy path for the test
        path = "/tmp/flexget_password";
      };

      systemd.services.flexget-password-setup = {
        # Ensure the mock password file exists before the setup runs
        preStart = ''
          echo "testpassword123" > /tmp/flexget_password
        '';
      };

      virtualisation.memorySize = 2048;
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("flexget.service")
    machine.wait_for_unit("flexget-password-setup.service")
    machine.wait_for_open_port(5050)

    # Check if we get the "running from source" error
    response = machine.succeed("curl -s http://localhost:5050")
    if "running from GitHub version" in response:
        machine.fail("Flexget WebUI assets are still missing (seen 'running from GitHub version' error)")

    # Check for successful load markers
    machine.succeed("curl -s http://localhost:5050 | grep -i 'FlexGet'")

    # Verify that the password was actually set in the database
    # We can check this by trying to log in via the API (minimal check)
    # The API returns 401 Unauthorized for wrong credentials
    machine.succeed("curl -X POST -H 'Content-Type: application/json' -d '{\"password\": \"testpassword123\"}' http://localhost:5050/api/login")
  '';
}
