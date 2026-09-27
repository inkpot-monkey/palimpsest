{
  config,
  lib,
  self,
  ...
}:

let
  cfg = config.custom.profiles.wireless;
  stationary = cfg.mode == "stationary";
in
{
  options.custom.profiles.wireless = {
    enable = lib.mkEnableOption "wireless (NetworkManager) configuration";

    # There are two shapes of wireless host in this fleet and they want opposite things, so
    # the shape is a mode rather than a pile of independent toggles.
    #
    #   roaming     — a laptop. Joins networks it has never seen, in places it does not
    #                 control: cafes, airports, hotels. Wants per-network MAC privacy and
    #                 wants the supplicant free to pick and re-pick the best BSS.
    #   stationary  — an appliance bolted to a shelf. Joins exactly one network, forever,
    #                 from one spot. Every degree of freedom the roaming host needs is a
    #                 liability here: it can only be exercised as an unplanned link change,
    #                 and on hosts like porcupineFish (recovery = a cold power-cycle) a link
    #                 change is the expensive kind of surprise.
    #
    # Default is `roaming`: it is the safer wrong answer (a stationary box on roaming
    # settings works, it just drifts), and it preserves what the fleet had before the split.
    mode = lib.mkOption {
      type = lib.types.enum [
        "roaming"
        "stationary"
      ];
      default = "roaming";
      example = "stationary";
      description = ''
        Whether this host moves between networks (`roaming`, e.g. a laptop) or sits on one
        network from one place (`stationary`, e.g. an audio appliance). Selects the MAC-address
        posture, and gates the band pin below.
      '';
    };

    # Why this is a knob and not a constant: which band is better is a property of the
    # *site*, not of the software. porcupineFish measures -69 dBm on 2.4 GHz and -76 dBm on
    # 5 GHz from where it sits, so for that host "better" is 2.4 — the opposite of the usual
    # advice. Measure before setting it (`nmcli dev wifi list --rescan yes`, /proc/net/wireless).
    band = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "bg" # 2.4 GHz
          "a" # 5 GHz
        ]
      );
      default = null;
      example = "bg";
      description = ''
        Pin the home network to one band. `null` leaves the choice to NetworkManager and the
        supplicant, which is right for a host that moves.

        On a stationary host a dual-band router will keep trying to steer the client between
        its radios (802.11v BSS Transition Management: `WNM: Disassociation Imminent`). If
        both radios are marginal, the client accepts, finds the other side no better, and gets
        steered back — measured on porcupineFish over one 18.5-hour window as 46 steering
        requests, 41 associations, 27 band changes, 15 disconnects and 56 failed association
        attempts, including a 6.5-minute gap with no link. Pinning the band makes those
        requests unactionable, which converts a flapping link into a consistently mediocre
        one. It does not improve signal: that needs a cable, or a better-placed AP.

        Prefer this over pinning `bssid`. A BSSID pin is stronger but ties the host to one
        radio's MAC address, so replacing the router costs a physical visit.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # A band pin only makes sense for a host that stays put; on a laptop it is a way to lose
    # wifi somewhere far from home. Fail the build rather than ship it.
    assertions = [
      {
        assertion = cfg.band == null || stationary;
        message = "custom.profiles.wireless.band pins one band, which only makes sense with mode = \"stationary\" (a roaming host needs both).";
      }
    ];

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

    # The link is this host's only path to everything, and on the wireless hosts it is the
    # least reliable part of the stack — so measure it. node-exporter's `wifi` collector is
    # off by default and is not in the monitoring profile's fleet-wide list (that list is
    # additive; see monitoring/exporters.nix), so contribute it from here: it lands on exactly
    # the hosts that have a radio to report on. Gives RSSI, link quality and retry counters,
    # which is the difference between "the speaker sounds odd sometimes" and a graph.
    services.prometheus.exporters.node.enabledCollectors = [ "wifi" ];

    networking = {
      networkmanager = {
        enable = true;
        wifi.powersave = false;
        # Roaming hosts default every *other* SSID (cafes, airports, hotels) to a per-network
        # pseudorandom MAC: each network sees one consistent address that is unlinkable to the
        # hardware MAC or to this host on any other network. A stationary host has no "other
        # SSID" to be private on, so the randomisation buys nothing and only adds a way for an
        # address to change unexpectedly — it keeps the burned-in MAC everywhere. (`home`
        # below pins `permanent` either way; this setting governs everything else.)
        wifi.macAddress = if stationary then "permanent" else "stable-ssid";
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
                # Home keeps the burned-in MAC so router DHCP reservations and
                # MAC-keyed rules survive. Matters most on porcupineFish, where a
                # changed address that fails to get a lease costs physical recovery.
                cloned-mac-address = "permanent";
              }
              // lib.optionalAttrs (cfg.band != null) { inherit (cfg) band; };
              wifi-security = {
                # No `auth-alg`: that setting selects a WEP authentication algorithm and is
                # inert under `wpa-psk` (the supplicant uses OPEN regardless), so it was
                # dropped rather than left to imply it was doing something.
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
