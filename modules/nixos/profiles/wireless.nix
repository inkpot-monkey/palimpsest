{
  config,
  lib,
  self, ...
}:

let
  cfg = config.custom.profiles.wireless;
in
{
  options.custom.profiles.wireless = {
    enable = lib.mkEnableOption "wireless (NetworkManager) configuration";
  };

  config = lib.mkIf cfg.enable {
    # 1. Declare the individual nested secrets
    sops.secrets."wifi/home/ssid" = {
      sopsFile = self.lib.getSecretPath "profiles/wireless.yaml";
    };
    sops.secrets."wifi/home/psk" = {
      sopsFile = self.lib.getSecretPath "profiles/wireless.yaml";
    };

    # 2. Build the environment file using a SOPS template
    sops.templates."wifi_home_env" = {
      content = ''
        WIFI_SSID=${config.sops.placeholder."wifi/home/ssid"}
        WIFI_PSK=${config.sops.placeholder."wifi/home/psk"}
      '';
      owner = "root";
      group = "networkmanager";
      mode = "0440";
    };

    # 3. Ensure the service waits for SOPS templates to render
    systemd.services.NetworkManager-ensure-profiles.after = [ "sops-install-secrets.service" ];
    systemd.services.NetworkManager-ensure-profiles.wants = [ "sops-install-secrets.service" ];

    networking = {
      networkmanager = {
        enable = true;
        wifi.powersave = false;
        ensureProfiles = {
          # 4. Point to the rendered template's path
          environmentFiles = [ config.sops.templates."wifi_home_env".path ];
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
  };
}
