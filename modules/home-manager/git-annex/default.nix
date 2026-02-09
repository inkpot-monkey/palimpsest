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
            unlock = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to unlock the repository (git annex adjust --unlock).";
            };
            assistant = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to enable the git-annex assistant for this repository.";
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
                    fetchTimeout = lib.mkOption {
                      type = lib.types.str;
                      default = "30s";
                      description = "Timeout for git fetch operations (e.g. '30s', '5m').";
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
                    params = lib.mkOption {
                      type = lib.types.attrsOf lib.types.str;
                      default = { };
                      description = "Additional parameters for special remotes (e.g. directory, rsyncurl).";
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
                    proxy = lib.mkOption {
                      type = lib.types.bool;
                      default = false;
                      description = "Whether to configure this remote as a git-annex proxy.";
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
            };
            wanted = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Preferred content expression (e.g. 'standard', 'nothing').";
            };
            group = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Standard group to assign (e.g. 'backup', 'transfer').";
            };
            numcopies = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Global numcopies setting to enforce.";
            };
          };
        }
      );
      default = { };
      description = "Declarative git-annex repositories.";
    };

    assistant = {
      enable = lib.mkEnableOption "git-annex assistant systemd service";

      autostartPaths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          List of paths to git repositories that the git-annex assistant should watch.
          These will be written to ~/.config/git-annex/autostart.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      home.packages = [
        pkgs.git
        pkgs.git-annex
        pkgs.gnupg
        pkgs.rsync
      ];

      home.activation.importGitAnnexGpgKey = lib.mkIf (cfg.gpgKeyFile != null) (
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if [ -f "${cfg.gpgKeyFile}" ]; then
            ${pkgs.gnupg}/bin/gpg --batch --import ${cfg.gpgKeyFile} || true
          else
            echo "Warning: git-annex gpgKeyFile configured but not found at ${cfg.gpgKeyFile}"
          fi
        ''
      );

      programs.git = {
        enable = true;
      };

      # Debugging aids (can be removed later or kept for troubleshooting)
      home.file."git-annex-config".text = builtins.toJSON cfg;
    })

    # Service Generation
    # We use xdg.configFile to manually generate systemd user units because
    # the systemd.user.services option merging is unreliable in some Home Manager
    # test environments.
    (lib.mkIf cfg.enable {
      xdg.configFile =
        let
          mkInitService =
            name: repo:
            let
              script = pkgs.writeShellScript "git-annex-init-${name}" ''
                set -e
                export PATH="${
                  lib.makeBinPath [
                    pkgs.git
                    pkgs.git-annex
                    pkgs.gnupg
                    pkgs.openssh
                    pkgs.rsync
                    pkgs.coreutils
                    pkgs.gnugrep
                    pkgs.gawk
                  ]
                }:$PATH"

                if [ ! -d "${repo.path}" ]; then
                  mkdir -p "${repo.path}"
                fi

                if [ ! -d "${repo.path}/.git" ]; then
                  git -C "${repo.path}" init
                fi

                if ! git -C "${repo.path}" annex info >/dev/null 2>&1; then
                  git -C "${repo.path}" annex init "${repo.description}"
                fi

                if ! git -C "${repo.path}" rev-parse HEAD >/dev/null 2>&1; then
                  git -C "${repo.path}" commit --allow-empty -m "Initial commit"
                fi

                ${lib.optionalString repo.unlock ''
                  # Check if already unlocked
                  if ! git -C "${repo.path}" branch --show-current | grep -q "adjusted/master(unlocked)"; then
                     git -C "${repo.path}" annex adjust --unlock
                  fi
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
                      
                      # Fetch with timeout to avoid hangs
                      timeout ${remote.fetchTimeout} git -C "${repo.path}" fetch "${remote.name}"
                      
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
                    ${lib.optionalString remote.proxy ''
                      git -C "${repo.path}" config remote.${remote.name}.annex-proxy true
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

                    ${lib.optionalString (remote.type == "git") ''
                      git -C "${repo.path}" annex sync "$TARGET_REMOTE_NAME" --no-content
                    ''}

                    ${lib.optionalString (remote.group != null) ''
                      git -C "${repo.path}" annex group "$TARGET_REMOTE_NAME" "${remote.group}"
                    ''}
                    ${lib.optionalString (remote.wanted != null) ''
                      git -C "${repo.path}" annex wanted "$TARGET_REMOTE_NAME" "${remote.wanted}"
                    ''}
                  ''}
                '') repo.remotes}
              '';
              unitFile = pkgs.writeText "git-annex-init-${name}.service" ''
                [Unit]
                Description=Initialize git-annex repository ${name}
                After=network-online.target
                Wants=network-online.target
                ${lib.optionalString (cfg.sshKeyFile != null) "ConditionPathExists=${cfg.sshKeyFile}"}

                [Service]
                Type=oneshot
                RemainAfterExit=true
                Environment="PATH=${
                  lib.makeBinPath [
                    pkgs.git
                    pkgs.git-annex
                    pkgs.gnupg
                    pkgs.openssh
                    pkgs.rsync
                    pkgs.coreutils
                    pkgs.gnugrep
                    pkgs.gawk
                  ]
                }:/usr/bin:/bin"
                Environment="GIT_SSH_COMMAND=ssh ${
                  lib.optionalString (cfg.sshKeyFile != null) "-i ${cfg.sshKeyFile} "
                }-o BatchMode=yes -o StrictHostKeyChecking=no -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
                ExecStart=${script}

                [Install]
                WantedBy=default.target
              '';
            in
            {
              "systemd/user/git-annex-init-${name}.service".source = unitFile;
              "systemd/user/default.target.wants/git-annex-init-${name}.service".source = unitFile;
            };

          assistantUnit = pkgs.writeText "git-annex-assistant.service" ''
            [Unit]
            Description=Git Annex Assistant
            Wants=${
              lib.concatMapStringsSep " " (n: "git-annex-init-${n}.service") (lib.attrNames cfg.repositories)
            }
            After=network.target ${
              lib.concatMapStringsSep " " (n: "git-annex-init-${n}.service") (lib.attrNames cfg.repositories)
            }

            [Service]
            ExecStart=${pkgs.git-annex}/bin/git-annex assistant --autostart
            Type=forking
            Restart=on-failure
            Environment="PATH=${
              lib.makeBinPath [
                pkgs.git
                pkgs.git-annex
                pkgs.gnupg
                pkgs.openssh
                pkgs.rsync
              ]
            }:/usr/bin:/bin"

            [Install]
            WantedBy=default.target
          '';

          assistantFiles =
            if cfg.assistant.enable then
              {
                "systemd/user/git-annex-assistant.service".source = assistantUnit;
                "systemd/user/default.target.wants/git-annex-assistant.service".source = assistantUnit;
              }
            else
              { };

          autostartFile =
            let
              enabledRepos = lib.filterAttrs (_n: v: v.assistant) cfg.repositories;
              repoPaths = lib.mapAttrsToList (_n: v: v.path) enabledRepos;
              allPaths = cfg.assistant.autostartPaths ++ repoPaths;
            in
            if allPaths != [ ] then
              {
                "git-annex/autostart".text = lib.concatStringsSep "\n" allPaths;
                "git-annex/autostart".onChange =
                  "${pkgs.systemd}/bin/systemctl --user restart git-annex-assistant.service || true";
              }
            else
              { };

          initFiles = lib.foldl' (acc: name: acc // (mkInitService name cfg.repositories.${name})) { } (
            lib.attrNames cfg.repositories
          );
        in
        initFiles // assistantFiles // autostartFile;
    })
  ];
}
