{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.git-annex;
in
{
  options.services.git-annex = {
    enable = lib.mkEnableOption "git-annex";

    repositories = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.path;
              description = "Path to the git-annex repository.";
            };
            description = lib.mkOption {
              type = lib.types.str;
              description = "Description for git annex init.";
            };
            uuid = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "The UUID of this repository. Useful for referencing it from other repositories.";
            };
            gateway = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to initialize this repository as a cluster gateway.";
            };
            clusterName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Name of the cluster to initialize if gateway is true.";
            };
            assistant = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to run the git-annex assistant for this repository.";
            };
            remotes = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    name = lib.mkOption {
                      type = lib.types.str;
                      description = "Name of the remote.";
                    };
                    url = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "URL of the git remote (for history syncing). Required for 'git' and hybrid remotes.";
                    };
                    type = lib.mkOption {
                      type = lib.types.str;
                      default = "git";
                      description = "Type of the remote. Defaults to 'git'. Use 'rsync', 'S3', etc. for special remotes.";
                    };

                    encryption = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Encryption setting for special remotes (e.g. 'none', 'shared', 'pubkey').";
                    };
                    expectedUUID = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Expected UUID of the remote. Verification is performed when the remote is added.";
                    };
                    clusterNode = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "If set, configures remote.<name>.annex-cluster-node to this value.";
                    };
                    wanted = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Preferred content expression for the remote (e.g. 'standard').";
                    };
                    group = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                      description = "Standard group to assign to the remote (e.g. 'backup').";
                    };
                  };
                }
              );
              default = [ ];
              description = "List of remotes (git, special, or hybrid) to add.";
              example = [
                { name = "backup"; url = "/var/lib/git-annex/backup"; }
                { name = "rsync_net"; url = "user@host:annex"; type = "rsync"; encryption = "none"; }
              ];
            };
            wanted = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Preferred content expression (e.g. 'standard', 'nothing').";
              example = "standard";
            };
            group = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Standard group to assign (e.g. 'backup', 'transfer').";
              example = "backup";
            };
            numcopies = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Global numcopies setting to enforce.";
            };
            tags = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "List of tags to automatically apply to new files.";
            };
            user = lib.mkOption {
              type = lib.types.str;
              default = "git-annex";
              description = "User to own this repository and run services.";
            };
            ownerGroup = lib.mkOption {
              type = lib.types.str;
              default = "git-annex";
              description = "Group to own this repository.";
            };
          };
        }
      );
      default = { };
      description = "Declarative git-annex repositories.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.git pkgs.git-annex ];

    users.users.git-annex = {
      isSystemUser = true;
      group = "git-annex";
      description = "Git Annex User";
      home = "/var/lib/git-annex";
      createHome = true;
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = [
        "<SCRUBBED_SSH_KEY>"
      ];
    };

    users.groups.git-annex = { };

    system.activationScripts.git-annex-ssh-key = ''
      if [ ! -f /var/lib/git-annex/.ssh/id_ed25519 ]; then
        mkdir -p /var/lib/git-annex/.ssh
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f /var/lib/git-annex/.ssh/id_ed25519 -C "git-annex@${config.networking.hostName}"
        chown -R git-annex:git-annex /var/lib/git-annex/.ssh
        chmod 700 /var/lib/git-annex/.ssh
        chmod 600 /var/lib/git-annex/.ssh/id_ed25519
      fi
    '';

    system.activationScripts.git-annex-repair = ''
      # Check if any git-annex repositories are missing their .git directory
      # If so, force the init service to restart to recreate them.
      RESTART_NEEDED=false
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: repo: ''
          if [ ! -d "${repo.path}/.git" ]; then
            echo "Git Annex repository ${name} appears damaged or missing. Scheduling repair..."
            # Only restart if the service is known to systemd (active or failed)
            # This prevents errors during initial activation when the unit is not yet loaded.
            if ${pkgs.systemd}/bin/systemctl is-active --quiet git-annex-init-${name}.service || \
               ${pkgs.systemd}/bin/systemctl is-failed --quiet git-annex-init-${name}.service; then
              ${pkgs.systemd}/bin/systemctl restart git-annex-init-${name}.service
            else
              echo "Service git-annex-init-${name}.service not found or not active. Assuming new deployment."
            fi
          fi
        '') cfg.repositories
      )}
    '';

    systemd.tmpfiles.rules = lib.mapAttrsToList (name: repo:
      "d '${repo.path}' 0770 ${repo.user} ${repo.ownerGroup} - -"
    ) cfg.repositories;

    systemd.services =
      let
        initServices = lib.mapAttrs' (
          name: repo:
          lib.nameValuePair "git-annex-init-${name}" {
            description = "Initialize git-annex repository ${name}";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              User = repo.user;
              Group = repo.ownerGroup;
              Type = "oneshot";
              RemainAfterExit = true;
            };
            path = with pkgs; [
              coreutils
              git
              git-annex
              gnugrep
              gawk
              gnupg
              openssh
              rsync
            ];
            script = ''
              if [ ! -d "${repo.path}" ]; then
                mkdir -p "${repo.path}"
              fi

              if [ ! -d "${repo.path}/.git" ]; then
                git -C "${repo.path}" init
              fi

              if ! git -C "${repo.path}" annex info >/dev/null 2>&1; then
                git -C "${repo.path}" config user.name "Git Annex Assistant"
                git -C "${repo.path}" config user.email "git-annex@localhost"
                git -C "${repo.path}" annex init "${repo.description}"
              fi

              if ! git -C "${repo.path}" rev-parse HEAD >/dev/null 2>&1; then
                git -C "${repo.path}" commit --allow-empty -m "Initial commit"
              fi

              ${lib.optionalString repo.gateway ''
                git -C "${repo.path}" annex initcluster "${
                  if repo.clusterName != null then repo.clusterName else "mycluster"
                }"
              ''}

              ${lib.optionalString (repo.wanted != null) ''
                git -C "${repo.path}" annex wanted . "${repo.wanted}"
              ''}

              ${lib.optionalString (repo.group != null) ''
                git -C "${repo.path}" annex group . "${repo.group}"
              ''}

              ${lib.optionalString (repo.numcopies != null) ''
                git -C "${repo.path}" annex numcopies ${toString repo.numcopies}
              ''}

              ${lib.concatMapStringsSep "\n" (remote: ''
                # Handle Git Remote (History)
                ${lib.optionalString (remote.url != null) ''
                  if ! git -C "${repo.path}" remote | grep -q "^${remote.name}$"; then
                    git -C "${repo.path}" remote add "${remote.name}" "${remote.url}"
                    git -C "${repo.path}" fetch "${remote.name}"
                    
                    ${lib.optionalString (remote.expectedUUID != null) ''
                      # Verify UUID
                      ACTUAL_UUID=$(git -C "${repo.path}" annex info "${remote.name}" | grep uuid | awk '{print $2}')
                      if [ "$ACTUAL_UUID" != "${remote.expectedUUID}" ]; then
                        echo "Error: UUID mismatch for remote ${remote.name}."
                        echo "Expected: ${remote.expectedUUID}"
                        echo "Actual:   $ACTUAL_UUID"
                        exit 1
                      fi
                    ''}
                  fi
                  ${lib.optionalString (remote.clusterNode != null) ''
                    git -C "${repo.path}" config remote.${remote.name}.annex-cluster-node "${remote.clusterNode}"
                  ''}
                ''}

                # Handle Special Remote (Content)
                ${lib.optionalString (remote.type != "git") ''
                  # For hybrid remotes (where url is set), we must use a different name for the special remote
                  # to avoid conflict with the git remote. We append "-content".
                  SPECIAL_REMOTE_NAME="${remote.name}${if remote.url != null then "-content" else ""}"
                  
                  # Check if the special remote is already initialized
                  if ! git -C "${repo.path}" annex info "$SPECIAL_REMOTE_NAME" | grep -q "type: ${remote.type}"; then
                    echo "Initializing special remote $SPECIAL_REMOTE_NAME..."
                    git -C "${repo.path}" annex initremote "$SPECIAL_REMOTE_NAME" \
                      type="${remote.type}" \
                      ${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${v}") (
                        (if remote.type == "rsync" && remote.url != null then { rsyncurl = remote.url; } else { }) //
                        (if remote.encryption != null then { encryption = remote.encryption; } else { })
                      ))} \
                      autoenable=true
                  fi
                ''}

                # Apply Remote Policy
                ${lib.optionalString (remote.group != null || remote.wanted != null) ''
                  TARGET_REMOTE_NAME="${remote.name}${if remote.type != "git" && remote.url != null then "-content" else ""}"
                  
                  # Ensure git-annex knows about the remote's UUID (only needed for git remotes)
                  ${lib.optionalString (remote.type == "git") ''
                    git -C "${repo.path}" annex sync "$TARGET_REMOTE_NAME" --no-content >/dev/null 2>&1 || true
                  ''}
                  
                  ${lib.optionalString (remote.group != null) ''
                    git -C "${repo.path}" annex group "$TARGET_REMOTE_NAME" "${remote.group}"
                  ''}
                  ${lib.optionalString (remote.wanted != null) ''
                    git -C "${repo.path}" annex wanted "$TARGET_REMOTE_NAME" "${remote.wanted}"
                  ''}
                ''}
              '') repo.remotes}

              ${lib.optionalString (repo.gateway && (lib.any (r: r.clusterNode != null) repo.remotes)) ''
                git -C "${repo.path}" annex updatecluster
              ''}

              ${lib.optionalString (repo.tags != [ ]) ''
                # Create post-commit hook to auto-tag new files
                mkdir -p "${repo.path}/.git/hooks"
                cat > "${repo.path}/.git/hooks/post-commit" << 'EOF'
                #!/bin/sh
                # Auto-tag files committed by the assistant
                # We use git diff to find changed files in the last commit
                # and apply the tag.
                
                # Check if there are any changes in the last commit
                if git rev-parse --verify HEAD >/dev/null 2>&1; then
                    # Get list of added/modified files
                    # We use -z for null-terminated output to handle spaces in filenames
                    # and xargs -0 to pass them to git annex metadata
                    git diff-tree -r --name-only --no-commit-id -z HEAD | \
                      xargs -0 -r git annex metadata \
                        ${lib.concatMapStringsSep " " (tag: "--tag=${tag}") repo.tags} \
                        >/dev/null 2>&1
                fi
                EOF
                chmod +x "${repo.path}/.git/hooks/post-commit"
              ''}
            '';
          }
        ) cfg.repositories;

        assistantServices = lib.mapAttrs' (
          name: repo:
          lib.nameValuePair "git-annex-assistant-${name}" (
            lib.mkIf repo.assistant {
              description = "Git Annex Assistant for ${name}";
              after = [
                "network.target"
                "git-annex-init-${name}.service"
              ];
              wantedBy = [ "multi-user.target" ];
              path = [
                pkgs.git
                pkgs.git-annex
                pkgs.openssh
                pkgs.rsync
                pkgs.gnupg
              ];
              serviceConfig = {
                User = repo.user;
                Group = repo.ownerGroup;
                ExecStart = "${pkgs.git-annex}/bin/git-annex assistant";
                Type = "forking";
                Restart = "on-failure";
                WorkingDirectory = repo.path;
              };
            }
          )
        ) cfg.repositories;
      in
      initServices // assistantServices;
  };
}
