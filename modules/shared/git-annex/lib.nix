# Pure helpers shared by the NixOS service module
# (modules/nixos/services/git-annex) and the home-manager module
# (modules/homeManager/git-annex). Both build a git-annex repository init
# shell script from the same per-repository options; these are the fragments
# that are identical between them, factored out so the two cannot drift.
{ lib }:
let
  # git-annex's four trust levels map to four distinct subcommands.
  trustCommand =
    trust:
    {
      trusted = "trust";
      semitrusted = "semitrust";
      untrusted = "untrust";
      dead = "dead";
    }
    .${trust};

  # A hybrid remote (a git remote that also carries content) gets a separate
  # "-content" special remote so the git remote and the special remote do not
  # collide on a single name. Plain git remotes and pure special remotes keep
  # their own name. Safe to call from inside a `type != "git"` block too: the
  # extra guard is simply redundant there.
  contentSuffix = remote: lib.optionalString (remote.type != "git" && remote.url != null) "-content";
in
{
  inherit trustCommand contentSuffix;

  # Put the repository on an adjusted branch so annexed files are real,
  # editable files in the working tree instead of symlinks into
  # .git/annex/objects. When `repo.thin` is set, the working-tree file is a
  # hardlink to the annex object (1x disk) rather than an independent copy (2x);
  # set annex.thin BEFORE adjusting so the adjusted worktree is materialised thin.
  mkUnlock =
    repo:
    lib.optionalString repo.unlock ''
      ${lib.optionalString repo.thin ''
        git -C "${repo.path}" config annex.thin true
      ''}
      # Only adjust if not already on the unlocked branch.
      if ! git -C "${repo.path}" branch --show-current | grep -q "adjusted/master(unlocked)"; then
        git -C "${repo.path}" annex adjust --unlock
      fi
    '';

  # The per-remote handling loop — add the git remote (with a bounded, retrying
  # fetch), initialise any special/hybrid remote, then apply group/wanted/trust
  # policy. Shared verbatim by both modules so the two cannot drift. Every step
  # is written to be safe under `set -e`:
  #   - the fetch is bounded by `remote.fetchTimeout` (both submodules carry it);
  #   - the UUID check is guarded so a no-match `grep` cannot abort init;
  #   - policy/trust failures warn instead of aborting.
  mkRemotesScript =
    repo:
    lib.concatMapStringsSep "\n" (remote: ''
      # Handle Git Remote (History)
      ${lib.optionalString (remote.url != null) ''
        if ! git -C "${repo.path}" remote | grep -q "^${remote.name}$"; then
          git -C "${repo.path}" remote add "${remote.name}" "${remote.url}"
          # Retry the fetch: at boot the remote host/repo may not be ready yet
          # (sshd still starting, peer's init service not finished). Each attempt
          # is bounded by fetchTimeout. Fail loudly only after the retries.
          fetched=false
          for _attempt in $(seq 1 30); do
            if timeout ${remote.fetchTimeout} git -C "${repo.path}" fetch "${remote.name}"; then
              fetched=true
              break
            fi
            echo "Fetch of remote ${remote.name} failed; retrying in 2s..."
            sleep 2
          done
          if [ "$fetched" != true ]; then
            echo "Error: could not fetch remote ${remote.name} after retries."
            exit 1
          fi

          ${lib.optionalString (remote.expectedUUID != null) ''
            # Verify UUID. Guarded: under `set -e` a no-match grep would otherwise
            # abort the whole init, so capture the pipeline in an `if`.
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
        ${lib.optionalString remote.proxy ''
          git -C "${repo.path}" config remote.${remote.name}.annex-proxy true
        ''}
        ${lib.optionalString (remote.cost != null) ''
          git -C "${repo.path}" config remote.${remote.name}.annex-cost ${toString remote.cost}
        ''}
      ''}

      # Handle Special Remote (Content)
      ${lib.optionalString (remote.type != "git") ''
        # Hybrid remotes (url set) use a distinct "-content" name so the git
        # remote and the special remote do not collide on one name.
        SPECIAL_REMOTE_NAME="${remote.name}${contentSuffix remote}"

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
        TARGET_REMOTE_NAME="${remote.name}${contentSuffix remote}"

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

      # Apply Trust Level
      ${lib.optionalString (remote.trust != null) ''
        TRUST_TARGET_NAME="${remote.name}${contentSuffix remote}"
        # Ensure git-annex knows the remote's UUID before trusting it.
        ${lib.optionalString (remote.type == "git") ''
          git -C "${repo.path}" annex sync "$TRUST_TARGET_NAME" --no-content || true
        ''}
        git -C "${repo.path}" annex ${trustCommand remote.trust} "$TRUST_TARGET_NAME" || echo "Warning: Failed to set trust for ${remote.name}"
      ''}
    '') repo.remotes;

  # A post-commit hook that tags newly committed files. git's post-commit hook
  # fires on an explicit `git commit`; the assistant commits via its own
  # internal machinery and does NOT invoke it.
  mkAutoTagHook =
    repo:
    lib.optionalString (repo.tags != [ ]) ''
      # Auto-tag files added via an explicit `git commit`.
      mkdir -p "${repo.path}/.git/hooks"
      cat > "${repo.path}/.git/hooks/post-commit" << 'EOF'
      #!/bin/sh
      if git rev-parse --verify HEAD >/dev/null 2>&1; then
          # -z/-0 keeps filenames with spaces intact.
          git diff-tree -r --name-only --no-commit-id -z HEAD | \
            xargs -0 -r git annex metadata \
              ${lib.concatMapStringsSep " " (tag: "--tag=${tag}") repo.tags} \
              >/dev/null 2>&1
      fi
      EOF
      chmod +x "${repo.path}/.git/hooks/post-commit"
    '';
}
