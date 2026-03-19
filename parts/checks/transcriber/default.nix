{
  self,
  pkgs,
  ...
}:

pkgs.testers.nixosTest {
  name = "transcriber-test";

  nodes.machine =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        self.nixosProfiles.transcriber
      ];

      config = {
        services.transcription-node = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9999;
        };

        # Increased memory for real whisperx execution
        virtualisation.memorySize = 8192;

        # Add netcat for testing
        environment.systemPackages = [ pkgs.netcat ];

        # Disable nix-command/flakes in the VM to speed up
        nix.settings.experimental-features = lib.mkForce [ ];
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("whisper-api.socket")

    # Check that the socket is listening
    machine.succeed("nc -z 127.0.0.1 9999")

    # NOTE: Real execution will fail without models/network
    # machine.succeed("echo 'dummy audio' | nc -N 127.0.0.1 9999")
  '';
}
