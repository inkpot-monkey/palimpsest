{
  config,
  lib,
  inputs,
  self,
  ...
}:
{
  options.custom.home.profiles.git-annex = {
    enable = lib.mkEnableOption "git-annex assistant for file synchronization";

    metrics.enable = lib.mkEnableOption ''
      publishing this user's git-annex health metrics to the node-exporter textfile
      collector, so the workstation's ~/Pictures sync is visible on the fleet Backups
      board the same way a host repo is. Off by default and NixOS-gated: it only works
      where the host runs the monitoring exporters and has added this user to the
      node-exporter group, which the host must arrange alongside setting this (see
      hosts/default.nix)
    '';

    alert.enable = lib.mkEnableOption ''
      paging #infra-alerts when this user's ~/Pictures sync breaks — a user-level watcher
      over the metrics above. Runs as the user, so its webhook secret is decrypted by the
      user's OWN sops (the admin key already on this workstation): no host re-key, and the
      secret never leaves the user's domain. Requires metrics.enable
    '';
  };

  imports = [
    inputs.self.homeManagerModules.git-annex
  ];

  config = lib.mkIf config.custom.home.profiles.git-annex.enable (
    lib.mkMerge [
      {
        sops.secrets.git_annex_ssh_key = {
          key = "git_annex/ssh_key/private";
          sopsFile = self.lib.getSecretFile "git-annex";
        };

        services.git-annex = {
          enable = true;
          sshKeyFile = config.sops.secrets.git_annex_ssh_key.path;
          # Gated by the host (see the option): the writer needs node-exporter group write,
          # which only the NixOS side can grant.
          metrics.enable = config.custom.home.profiles.git-annex.metrics.enable;
          repositories = {
            # ~/Pictures is the working copy. unlock = true keeps photos as real,
            # editable files (image viewers see files, not annex symlinks). The
            # assistant auto-syncs to kelpy's `pictures` repo over SSH, which wants
            # all content — so every photo gets a second copy on kelpy. A plain
            # client <-> server pair: no cluster, proxy, or encryption.
            pictures = {
              path = "${config.home.homeDirectory}/Pictures";
              description = "inkpotmonkey-pictures";
              unlock = true;
              # Hardlink worktree files to the annex objects (1x disk, not 2x). Safe
              # here: the assistant re-ingests any in-place edit, and kelpy's repo
              # holds a full second copy so the pre-edit content is never lost.
              thin = true;
              # Per-repo opt-in that puts ~/Pictures into ~/.config/git-annex/autostart
              # so the assistant (assistant.enable below) actually watches it. Without
              # this the assistant unit starts with nothing to watch and exits 1.
              assistant = true;
              remotes = [
                {
                  name = "kelpy";
                  url = "git-annex@kelpy:~/pictures";
                }
              ];
            };
          };
          assistant.enable = true;
        };
      }

      # User-level replication alert (option C). The webhook secret comes from THIS user's
      # sops — the admin key already decrypts matrix.yaml here, so no host re-key and no
      # host secret. A sops.template assembles the same URL the fleet watcher uses
      # (https://hookshot.<domain>/webhook/<hookId>).
      (lib.mkIf config.custom.home.profiles.git-annex.alert.enable {
        sops.secrets.infra_alerts_hook_id.sopsFile = self.lib.getSecretFile "matrix";
        sops.templates."git-annex-alert-webhook-url".content =
          "https://hookshot.${self.settings.primaryDomain}/webhook/${config.sops.placeholder.infra_alerts_hook_id}";
        services.git-annex.alert = {
          enable = true;
          webhookUrlFile = config.sops.templates."git-annex-alert-webhook-url".path;
        };
      })
    ]
  );
}
