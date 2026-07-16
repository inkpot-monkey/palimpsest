# Pure helpers shared by the NixOS service module
# (modules/nixos/services/git-annex) and the home-manager module
# (modules/homeManager/git-annex). Both build a git-annex repository init
# shell script from the same per-repository options; these are the fragments
# that are identical between them, factored out so the two cannot drift.
{ lib }:
{
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
