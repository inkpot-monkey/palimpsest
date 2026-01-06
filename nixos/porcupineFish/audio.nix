{
  config,
  pkgs,
  lib,
  ...
}:

{
  # --- RASPBERRY PI HARDWARE ---
  # High-level RPi hardware configuration via nvmd/nixos-raspberrypi
  hardware.raspberry-pi.config = {
    all = {
      base-dt-params = {
        audio = {
          enable = true;
          value = lib.mkForce "off";
        };
        i2c_arm = {
          enable = true;
          value = "on";
        };
        i2s = {
          enable = true;
          value = "on";
        };
      };
      dt-overlays = {
        hifiberry-dacplusadcpro = {
          enable = true;
          params = { };
        };
        disable-bt = {
          enable = true;
          params = { };
        };
      };
    };
  };

  # Standard NixOS hardware settings
  hardware.i2c.enable = true;

  # Explicitly load necessary modules (Safeguard)
  boot.kernelModules = [
    "i2c-dev"
    "i2c-bcm2835"
    "snd-soc-hifiberry-dacplusadcpro"
    "snd-soc-pcm512x-i2c"
    "snd-soc-pcm186x-i2c"
  ];

  # Disable onboard audio to avoid conflicts
  boot.blacklistedKernelModules = [ "snd_bcm2835" ];

  # --- AUDIO STACK (PipeWire) ---
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If using as a system-wide daemon (not typical, but common for headless audio nodes)
    # systemWide = true;
    # However, for Mopidy standard user service + ALSA backend is usually sufficient.
  };

  # --- PACKAGES ---
  environment.systemPackages = with pkgs; [
    alsa-utils
    sox
    bc
    pavucontrol # Useful if you have X11 forwarding, otherwise use pactl/wpctl
  ];

  # --- SECRETS ---

  # 1. Spotifyd Password
  sops.secrets."spotify/password" = {
    owner = "spotifyd";
    group = "spotifyd"; # often same as user
  };

  # 2. Mopidy Config (Spotify Credentials)
  sops.secrets."mopidy/config" = {
    owner = "mopidy";
    group = "mopidy";
  };

  # --- SERVICES ---
  services.spotifyd = {
    enable = true;
    settings = {
      global = {
        device_name = config.networking.hostName;
        # Explicitly use ALSA backend which PipeWire intercepts
        backend = "alsa";
        device = "default"; # Will target PipeWire default sink
        bitrate = 320;

        # Username matches the sops file content you should create
        username = "3twskugod0qopz0fr5f3ri22h";

        # Read password from the decrypted sops file
        password_cmd = "cat ${config.sops.secrets."spotify/password".path}";
      };
    };
  };

  services.mopidy = {
    enable = true;
    extensionPackages = [
      pkgs.mopidy-iris # Web UI
      pkgs.mopidy-spotify # Spotify Premium
      pkgs.mopidy-local # Local files
    ];

    # Load the secret config which contains the [spotify] block
    extraConfigFiles = [ config.sops.secrets."mopidy/config".path ];

    settings = {
      core = {
        restore_state = true;
      };
      audio = {
        output = "alsasink";
      };
      iris = {
        enabled = true;
        country = "US";
        locale = "en_US";
      };
      http = {
        enabled = true;
        hostname = "0.0.0.0";
        port = 6680;
        zeroconf = "Mopidy HTTP Server on NixHiFi";
      };
    };
  };

  # Open the firewall for the Web UI
  networking.firewall.allowedTCPPorts = [ 6680 ];
}
