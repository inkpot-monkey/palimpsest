_:

{
  virtualisation.oci-containers.containers.whisper-asr = {
    image = "onerahmet/openai-whisper-asr-webservice:latest";

    ports = [ "9999:9000" ];

    environment = {
      # You can switch this to 'whisperx' or 'faster_whisper' depending on preference
      ASR_ENGINE = "whisperx";
      ASR_MODEL = "base";
      # ASR_DEVICE = "cuda"; # Uncomment if using GPU
    };

    # Optional: Persist the downloaded models so it doesn't re-download on every restart
    volumes = [
      "/var/lib/whisper-cache:/root/.cache"
    ];

    extraOptions = [
      # "--device=nvidia.com/gpu=all" # Uncomment if using an Nvidia GPU
    ];
  };

  # Open the firewall port so Subgen on the VPS can reach it via your Tailscale/VPN IP
  networking.firewall.allowedTCPPorts = [ 9999 ];
}
