{
  config,
  lib,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.monitoring-exporters;
  # Flake provenance, baked into the closure at build time so each host reports the
  # rev it was actually built from. `self.rev` exists only for a clean tree and
  # `self.dirtyRev` only for a dirty one — the `or` chain tolerates either (and a
  # tarball input with neither). This is how the fleet-overview board detects a host
  # that is running behind the others: distinct revisions == config drift.
  configRev = self.rev or self.dirtyRev or "unknown";
  configLastModified = toString (self.lastModified or 0);
in
{
  options.custom.profiles.monitoring-exporters = {
    enable = lib.mkEnableOption "monitoring exporters (node exporter) configuration";
  };

  config = lib.mkIf cfg.enable {
    # Make `nixos-version` (and the metric above) report the flake rev this host
    # was built from. mkDefault so a host may still override it elsewhere.
    system.configurationRevision = lib.mkDefault configRev;

    services.prometheus.exporters = {
      node = {
        enable = true;
        enabledCollectors = [
          "systemd"
          "textfile"
        ];
        extraFlags = [ "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files" ];
      };
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

          # Config provenance — constant per generation (baked at build time), but
          # re-emitted here so the value survives a wiped textfile dir. The rev rides
          # in a label (info-metric convention: value is always 1); lastModified is a
          # plain epoch gauge so `time() - metric` yields the running config's age.
          echo "# HELP nixos_configuration_revision_info Flake git revision the running system was built from" >> $prom_file
          echo "# TYPE nixos_configuration_revision_info gauge" >> $prom_file
          echo 'nixos_configuration_revision_info{revision="${configRev}"} 1' >> $prom_file

          echo "# HELP nixos_configuration_last_modified_seconds Flake lastModified (epoch) of the running config" >> $prom_file
          echo "# TYPE nixos_configuration_last_modified_seconds gauge" >> $prom_file
          echo "nixos_configuration_last_modified_seconds ${configLastModified}" >> $prom_file
        '';
        wantedBy = [ "multi-user.target" ];
      };

      timers.nixos-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          # Daily, not hourly: the service does a full recursive `du -sb /nix/store`
          # walk. Every metric it emits is constant per generation except store
          # size (which drifts slowly), and the unit already re-runs on each deploy
          # — its script embeds the flake rev, so the unit changes and
          # switch-to-configuration restarts it. So hourly only bought I/O; daily
          # still catches GC-driven store shrinkage.
          OnUnitActiveSec = "1d";
          Unit = "nixos-metrics.service";
        };
      };
    };

    # Delay exporter startup until Tailscale creates the interface
    systemd.services.prometheus-node-exporter = {
      after = [ "tailscaled.service" ];
      requires = [ "tailscaled.service" ];
    };
  };
}
