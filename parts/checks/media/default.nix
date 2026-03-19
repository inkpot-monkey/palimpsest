{
  self,
  pkgs,
  inputs,
  ...
}:

pkgs.testers.nixosTest {
  name = "media-test";

  nodes = {
    server =
      { lib, ... }:
      {
        _module.args.inputs = inputs;
        imports = [ self.nixosProfiles.transcriber ];
        services.transcription-node = {
          enable = true;
          listenAddress = "0.0.0.0";
          port = 9999;
        };

        # Increased memory for real whisperx execution
        virtualisation.memorySize = 8192;

        networking.firewall.allowedTCPPorts = [ 9999 ];
        nix.settings.experimental-features = lib.mkForce [ ];
      };

    client =
      { lib, ... }:
      {
        _module.args.inputs = inputs;
        imports = [
          self.nixosProfiles.media
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
          transcriptionServer = {
            address = "server";
            port = 9999;
          };
        };

        # Increased memory for client
        virtualisation.memorySize = 8192;

        # Disable nix-command/flakes in the VM
        nix.settings.experimental-features = lib.mkForce [ ];
      };
  };

  testScript = ''
    server.start()
    client.start()

    server.wait_for_unit("whisper-api.socket")
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

    # Create a dummy video file
    client.succeed("touch dummy.mkv")

    # NOTE: Real execution will fail without models/network/valid-media
    # client.succeed("auto-sub dummy.mkv")
  '';
}
