# Prometheus exporters configuration
{
  pkgs,
  lib,
  ...
}:

{
  services.prometheus.exporters = {
    node = {
      enable = true;
      enabledCollectors = [
        "systemd"
        "textfile"
      ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files" ];
    };
    systemd = {
      enable = true;
      listenAddress = "0.0.0.0";
    };
    smartctl = {
      enable = true;
      listenAddress = "0.0.0.0";
    };
    blackbox = {
      enable = true;
      configFile = pkgs.writeText "blackbox.yml" (
        builtins.toJSON {
          modules = {
            icmp = {
              prober = "icmp";
            };
          };
        }
      );
    };
  };

  # Fix for systemd-exporter failing to talk to dbus on some kernels (e.g. VPS)
  systemd.services.prometheus-systemd-exporter.serviceConfig = {
    PrivateDevices = lib.mkForce false;
    ProtectSystem = lib.mkForce "no";
    ProtectHome = lib.mkForce false;
    PrivateTmp = lib.mkForce false;
    NoNewPrivileges = lib.mkForce false;
    RestrictAddressFamilies = lib.mkForce [ ];
    RestrictNamespaces = lib.mkForce false;
  };

  # Similarly for node-exporter to ensure its systemd collector works
  systemd.services.prometheus-node-exporter.serviceConfig = {
    RestrictAddressFamilies = lib.mkForce [ ];
    RestrictNamespaces = lib.mkForce false;
  };

  systemd = {
    tmpfiles.rules = [
      "d /var/lib/prometheus-node-exporter-text-files 0775 node-exporter node-exporter -"
    ];

    # NixOS metrics for Prometheus
    services.nixos-metrics = {
      serviceConfig.Type = "oneshot";
      path = with pkgs; [
        nix
        coreutils
      ];
      script = ''
        prom_file="/var/lib/prometheus-node-exporter-text-files/nixos.prom"
        echo "# HELP nixos_generations_count Total number of NixOS generations" > $prom_file
        echo "# TYPE nixos_generations_count gauge" >> $prom_file
        count=$(nix-env --list-generations -p /nix/var/nix/profiles/system | wc -l)
        echo "nixos_generations_count $count" >> $prom_file

        echo "# HELP nixos_store_paths_count Total number of paths in /nix/store" >> $prom_file
        echo "# TYPE nixos_store_paths_count gauge" >> $prom_file
        count=$(ls -1 /nix/store | wc -l)
        echo "nixos_store_paths_count $count" >> $prom_file

        echo "# HELP nixos_store_size_bytes Total size of /nix/store in bytes" >> $prom_file
        echo "# TYPE nixos_store_size_bytes gauge" >> $prom_file
        size=$(du -sb /nix/store | cut -f1)
        echo "nixos_store_size_bytes $size" >> $prom_file
      '';
      wantedBy = [ "multi-user.target" ];
    };

    timers.nixos-metrics = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1m";
        OnUnitActiveSec = "1h";
        Unit = "nixos-metrics.service";
      };
    };
  };

  # Delay exporter startup until Tailscale creates the interface
  systemd.services.prometheus-node-exporter = {
    after = [ "tailscaled.service" ];
    requires = [ "tailscaled.service" ];
  };
  systemd.services.prometheus-systemd-exporter = {
    after = [ "tailscaled.service" ];
    requires = [ "tailscaled.service" ];
  };
  systemd.services.prometheus-smartctl-exporter = {
    after = [ "tailscaled.service" ];
    requires = [ "tailscaled.service" ];
  };
}
