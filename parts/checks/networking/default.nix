{
  self,
  pkgs,
  inputs,
  ...
}:

pkgs.testers.nixosTest {
  name = "networking-test";

  nodes.machine =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        self.nixosProfiles.wireless
      ];

      config = {
        # The wireless profile reads `self.lib.getSecretPath`; nixosTest nodes do
        # not inherit the flake's specialArgs, so pass it in explicitly.
        _module.args.self = self;

        # Satisfy sops assertion
        sops.age.keyFile = "/etc/dummy-sops-key";
        system.activationScripts.create-dummy-sops-key = ''
          mkdir -p /etc
          echo "AGE-SECRET-KEY-1H6VNY7V4QW7Z8E4G9Q8Z5Z5Z5Z5Z5Z5Z5Z5Z5Z5Z5Z5Z5Z5Z5Z5SXXXXX" > /etc/dummy-sops-key
        '';

        # Mock the rendered file directly so NetworkManager-ensure-profiles can find it
        # without sops-install-secrets having to succeed in the VM
        system.activationScripts.mock-sops-output = ''
          mkdir -p /run/secrets/rendered
          cat <<EOF > /run/secrets/rendered/wifi_home_env
          WIFI_SSID=test-ssid
          WIFI_PSK=test-psk
          EOF
          chmod 0440 /run/secrets/rendered/wifi_home_env
          chown root:networkmanager /run/secrets/rendered/wifi_home_env
        '';

        sops.defaultSopsFile = pkgs.writeText "dummy-sops.yaml" ''
          wifi:
            home:
              ssid: "dummy-ssid"
              psk: "dummy-psk"
        '';
        sops.validateSopsFiles = false;

        # Without this the profile's `mkIf` gate leaves ensureProfiles empty, so
        # NetworkManager-ensure-profiles.service is never generated and the test
        # asserts against a switched-off module.
        custom.profiles.wireless.enable = true;

        networking.networkmanager.enable = true;

        # Disable nix-command/flakes in the VM to speed up and avoid issues
        nix.settings.experimental-features = lib.mkForce [ ];
      };
    };

  testScript = ''
    machine.start()

    # Wait for the machine to boot
    machine.wait_for_unit("multi-user.target")

    # Wait for NetworkManager
    machine.wait_for_unit("NetworkManager.service")

    # Check if the templates were rendered (our mock)
    machine.succeed("ls /run/secrets/rendered/wifi_home_env")

    # Start/wait for the profile creation service
    machine.succeed("systemctl start NetworkManager-ensure-profiles.service")

    # Verify the profile exists in NM runtime path
    machine.succeed("ls /run/NetworkManager/system-connections/home.nmconnection")

    # Home pins the burned-in MAC: a host that silently moved to a synthesised
    # address could fail to match a router DHCP reservation, which on the
    # headless pi costs physical recovery.
    machine.succeed(
        "grep -x 'cloned-mac-address=permanent' "
        "/run/NetworkManager/system-connections/home.nmconnection"
    )

    # Every other SSID defaults to a per-network pseudorandom MAC.
    machine.succeed(
        "grep -x 'wifi.cloned-mac-address=stable-ssid' /etc/NetworkManager/NetworkManager.conf"
    )
  '';
}
