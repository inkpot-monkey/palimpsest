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
      { lib, ... }:
      {
        _module.args.self = self;
        _module.args.inputs = inputs;
        imports = [
          self.nixosProfiles.media
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
        };

        # Mock SOPS for the test
        sops.gnupg.home = "/var/lib/sops";
        systemd.services.flexget.preStart = lib.mkForce "mkdir -p /var/lib/flexget";

        # Increased memory for client
        virtualisation.memorySize = 8192;

        # Disable nix-command/flakes in the VM
        nix.settings.experimental-features = lib.mkForce [ ];
      };
  };

  testScript = ''
    client.start()

    client.wait_for_unit("jellyfin.service")
    client.wait_for_open_port(8096)

    # Verify Jellyfin cache ownership
    client.succeed("ls -ld /var/cache/jellyfin | grep jellyfin")

    # Validate FlexGet configuration schema
    # Copy config to a temporary directory to avoid lock conflict in /var/lib/flexget
    client.succeed("mkdir -p /tmp/flexget")
    client.succeed("cp /var/lib/flexget/flexget.yml /tmp/flexget/config.yml")
    client.execute("cat /tmp/flexget/config.yml >&2")
    client.succeed("HOME=/tmp/flexget flexget -c /tmp/flexget/config.yml check")

    client.wait_for_open_port(5050)
  '';
}
