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

    sshKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to the private SSH key file to use for git-annex (e.g. /run/secrets/git-annex-key).";
    };

    gpgKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to the GPG key file to import for git-annex (e.g. /run/secrets/gpg-key).";
    };

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
                    params = lib.mkOption {
                      type = lib.types.attrsOf lib.types.str;
                      default = { };
                      description = "Additional parameters for special remotes (e.g. keyid, directory).";
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
                {
                  name = "backup";
                  url = "/var/lib/git-annex/backup";
                }
                {
                  name = "rsync_net";
                  url = "user@host:annex";
                  type = "rsync";
                  encryption = "none";
                }
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
    environment.systemPackages = [
      pkgs.git
      pkgs.git-annex
    ];

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
      mkdir -p /var/lib/git-annex/.ssh
      chown git-annex:git-annex /var/lib/git-annex/.ssh
      chmod 700 /var/lib/git-annex/.ssh

      ${
        if cfg.sshKeyFile != null then
          ''
            # Install provided SSH key from file (runtime path)
            if [ -f "${cfg.sshKeyFile}" ]; then
              cp "${cfg.sshKeyFile}" /var/lib/git-annex/.ssh/id_ed25519
              chown git-annex:git-annex /var/lib/git-annex/.ssh/id_ed25519
              chmod 600 /var/lib/git-annex/.ssh/id_ed25519
            else
              echo "Warning: git-annex sshKeyFile configured but not found at ${cfg.sshKeyFile}"
            fi
          ''
        else
          ''
            # Generate ephemeral key if none provided (fallback)
            if [ ! -f /var/lib/git-annex/.ssh/id_ed25519 ]; then
              ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f /var/lib/git-annex/.ssh/id_ed25519 -C "git-annex@${config.networking.hostName}"
              chown git-annex:git-annex /var/lib/git-annex/.ssh/id_ed25519
              chmod 600 /var/lib/git-annex/.ssh/id_ed25519
            fi
          ''
      }
    '';

    system.activationScripts.git-annex-gpg-key = lib.mkIf (cfg.gpgKeyFile != null) ''
      mkdir -p /var/lib/git-annex/.gnupg
      chown git-annex:git-annex /var/lib/git-annex/.gnupg
      chmod 700 /var/lib/git-annex/.gnupg

      # Import the key if it exists
      if [ -f "${cfg.gpgKeyFile}" ]; then
        ${pkgs.sudo}/bin/sudo -u git-annex ${pkgs.gnupg}/bin/gpg --batch --import ${cfg.gpgKeyFile} || true
      else
        echo "Warning: git-annex gpgKeyFile configured but not found at ${cfg.gpgKeyFile}"
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
            # Check if the service unit exists (is loaded)
            if ${pkgs.systemd}/bin/systemctl list-unit-files "git-annex-init-${name}.service" | grep -q "git-annex-init-${name}.service"; then
              ${pkgs.systemd}/bin/systemctl restart git-annex-init-${name}.service
              ${lib.optionalString repo.assistant ''
                # Ensure assistant is started after repair (since Conflicts stopped it)
                ${pkgs.systemd}/bin/systemctl start git-annex-assistant-${name}.service || true
              ''}
            else
              echo "Service git-annex-init-${name}.service not found. Assuming new deployment."
            fi
          fi
        '') cfg.repositories
      )}
    '';

    systemd.tmpfiles.rules = lib.mapAttrsToList (
      _name: repo: "d '${repo.path}' 0770 ${repo.user} ${repo.ownerGroup} - -"
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
            # Wait for SSH key file if configured (e.g. sops secret)
            unitConfig.ConditionPathExists = lib.optional (cfg.sshKeyFile != null) cfg.sshKeyFile;

            # Prevent race conditions with assistant
            # We use ExecStartPre to stop the assistant instead of Conflicts,
            # because Conflicts cancels the assistant's pending start job during boot.
            # We only stop if active to avoid cancelling the pending start job during boot.
            serviceConfig.ExecStartPre = "+${pkgs.bash}/bin/sh -c '${pkgs.systemd}/bin/systemctl is-active --quiet git-annex-assistant-${name}.service && ${pkgs.systemd}/bin/systemctl stop git-annex-assistant-${name}.service || true'";
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
                git -C "${repo.path}" config user.email "git-annex@localhost"
                git -C "${repo.path}" config receive.denyCurrentBranch updateInstead
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
                    # Removed || echo warning to ensure we fail if network/keys are wrong
                    git -C "${repo.path}" fetch "${remote.name}"
                    
                    ${lib.optionalString (remote.expectedUUID != null) ''
                      # Verify UUID
                      if ACTUAL_UUID=$(git -C "${repo.path}" annex info "${remote.name}" 2>/dev/null | grep uuid | awk '{print $2}'); then
                        if [ -n "$ACTUAL_UUID" ] && [ "$ACTUAL_UUID" != "${remote.expectedUUID}" ]; then
                          echo "Error: UUID mismatch for remote ${remote.name}."
                          echo "Expected: ${remote.expectedUUID}"
                          echo "Actual:   $ACTUAL_UUID"
                          exit 1
                        fi
                      else
                        echo "Warning: Could not verify UUID for remote ${remote.name} (network issue?)"
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
                      ${
                        lib.concatStringsSep " " (
                          lib.mapAttrsToList (k: v: "${k}=${v}") (
                            (if remote.type == "rsync" && remote.url != null then { rsyncurl = remote.url; } else { })
                            // (if remote.encryption != null then { inherit (remote) encryption; } else { })
                            // remote.params
                          )
                        )
                      } \
                      autoenable=true
                  fi
                ''}

                # Apply Remote Policy
                ${lib.optionalString (remote.group != null || remote.wanted != null) ''
                  TARGET_REMOTE_NAME="${remote.name}${
                    if remote.type != "git" && remote.url != null then "-content" else ""
                  }"

                  # Ensure git-annex knows about the remote's UUID (only needed for git remotes)
                  ${lib.optionalString (remote.type == "git") ''
                    git -C "${repo.path}" annex sync "$TARGET_REMOTE_NAME" --no-content
                  ''}

                  ${lib.optionalString (remote.group != null) ''
                    git -C "${repo.path}" annex group "$TARGET_REMOTE_NAME" "${remote.group}" || echo "Warning: Failed to set group for ${remote.name}"
                  ''}
                  ${lib.optionalString (remote.wanted != null) ''
                    git -C "${repo.path}" annex wanted "$TARGET_REMOTE_NAME" "${remote.wanted}" || echo "Warning: Failed to set wanted for ${remote.name}"
                  ''}
                ''}
              '') repo.remotes}

              ${lib.optionalString (repo.gateway && (lib.any (r: r.clusterNode != null) repo.remotes)) ''
                git -C "${repo.path}" annex updatecluster || echo "Warning: Failed to update cluster"
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
