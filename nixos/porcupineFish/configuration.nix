{ pkgs, inputs, config, self, ... }: {
  imports = [
    inputs.nixos-hardware.nixosModules.raspberry-pi-4
    inputs.sops-nix.nixosModules.sops
    "${inputs.nixpkgs}/nixos/modules/profiles/headless.nix"

    ../common/server.nix
    ../common/default.nix
    ../common/nix.nix
  ];

  sops = {
    age.sshKeyPaths = [
      "/etc/ssh/ssh_host_ed25519_key" # System key
    ];
    defaultSopsFile = self + "/secrets/secrets.yaml";
  };

  programs.mosh.enable = true;
  services.openssh = {
    settings = {
      ClientAliveInterval = 60;
      ClientAliveCountMax = 3;
    };
  };

  environment.systemPackages = with pkgs; [
    libraspberrypi
    raspberrypi-eeprom
    git
  ];

  sops.secrets."wifi/home/env" = {
    owner = "root";
    group = "networkmanager";
    mode = "0440";
  };

  powerManagement.enable = false;

  networking = {
    hostName = "porcupineFish";
    networkmanager = {
      enable = true;
      wifi.powersave = false;
      ensureProfiles = {
        environmentFiles = [ config.sops.secrets."wifi/home/env".path ];
        profiles = {
          home = {
            connection = {
              id = "home";
              type = "wifi";
            };
            wifi = {
              mode = "infrastructure";
              ssid = "$WIFI_SSID";
            };
            wifi-security = {
              auth-alg = "open";
              key-mgmt = "wpa-psk";
              psk = "$WIFI_PSK";
            };
          };
        };
      };
    };
  };

  services.navidrome = {
    enable = true;
    openFirewall = true; # Open firewall for Navidrome port
    settings.Address = "0.0.0.0";
  };

  boot = {
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
    blacklistedKernelModules = [ "snd-bcm2835" ];
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };

  hardware = {
    enableRedistributableFirmware = true;
    deviceTree.enable = true;
    deviceTree.overlays = [{
      name = "hifiberry-dacplusadcpro";
      dtboFile =
        "${pkgs.raspberrypifw}/share/raspberrypi/boot/overlays/hifiberry-dacplusadcpro.dtbo";
    }];
  };

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true; # if not already enabled
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };
  services.pulseaudio.enable = false;

  # Socket activation too slow for headless; start at boot instead.
  services.pipewire.socketActivation = false;
  # Start WirePlumber (with PipeWire) at boot.
  systemd.user.services.wireplumber.wantedBy = [ "default.target" ];
  users.users.root.linger = true; # keep user services running
  users.users.root.extraGroups = [ "audio" ];

  system.stateVersion = "25.11";
}
