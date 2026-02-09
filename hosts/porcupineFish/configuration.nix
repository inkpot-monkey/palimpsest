{
  pkgs,
  inputs,
  config,
  self,
  ...
}:
{
  imports = [
    inputs.sops-nix.nixosModules.sops
    "${inputs.nixpkgs}/nixos/modules/profiles/headless.nix"

    (self + /modules/nixos/common/server.nix)
    (self + /modules/nixos/common/base.nix)
    (self + /modules/nixos/common/pi.nix)
    ./audio.nix
  ];

  sops = {

    age.sshKeyPaths = [
      "/etc/ssh/ssh_host_ed25519_key" # System key
    ];
    defaultSopsFile = self + "/secrets/secrets.yaml";
  };

  environment.systemPackages = with pkgs; [
    git
  ];

  sops.secrets."wifi/home/env" = {
    owner = "root";
    group = "networkmanager";
    mode = "0440";
  };

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

  system.stateVersion = "25.11";
}
