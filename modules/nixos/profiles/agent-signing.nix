{
  config,
  lib,
  self,
  ...
}:

# agent-signing — the dedicated non-admin commit-signing key, placed on a host that runs
# agent sessions (ADR-0003).
#
# ── WHY THIS EXISTS AT ALL ──────────────────────────────────────────────────────────────
# The operator's home signs commits in BOTH modes: users/inkpotmonkey/modules/git.nix sets
# `signing.signByDefault = true`, which writes `commit.gpgSign` for every seat, with
# `signing.key = ~/.ssh/id_ed25519.pub`. `ssh-keygen -Y sign` then reads the SIBLING private
# key next to that `.pub`.
#
# A headless seat holds the public half in authorizedKeys and no private half, so every
# commit there fails with `No private key found for public key`. That was deliberate while
# such seats produced no commits — git.nix still says so — but rk1b now runs server-side
# agent sessions whose entire output IS commits, so the seat that "should not be producing
# commits" is the one we are asking to produce them.
#
# ── WHY THE HOST PROVIDES IT RATHER THAN THE HOME ───────────────────────────────────────
# Homes are built per MODE, not per host (the contract hardcodes `exposed = false` in a
# home's hostFacts because which seat binds it is unknowable there). So a home cannot say
# "on rk1b, sign with this other key": pointing `signing.key` at an rk1b-only path would
# break the cli home on kelpy, rk1a, porcupineFish and potbelliedSeahorse, and turning
# signing OFF per host is equally unexpressible — content selection is which module a mode
# names, and there is no `mkIf` on a session shape (users/AGENTS.md).
#
# So the home is left completely alone and its assumption is made TRUE here instead: the key
# really is at `~/.ssh/id_ed25519`, with its `.pub` beside it. The host provides, the home
# consumes, and the home never learns which host it is on — which is the contract's whole
# shape.
#
# ⚠ THE FILENAME IS A LEGIBILITY HAZARD, AND IT IS DELIBERATE. AGENTS.md says
# "`~/.ssh/id_ed25519` is the sops admin key (`&admin`) and decrypts everything" — true on
# sawtoothShark, and FALSE here. The same filename holds a different key on this host: a
# non-admin signing key that decrypts nothing. The alternative was a different filename plus
# a home change to point at it, which would have cost the zero-home-change property above.
# If you are reading this while wondering whether an agent host holds the admin key: it does
# not, and `ssh-keygen -lf` on the file will show `kelpy-aionui-signing` rather than the
# operator's personal key.
let
  cfg = config.custom.profiles.agent-signing;
  home = config.users.users.${cfg.user}.home;
  sshDir = "${home}/.ssh";

  identities = import (self.lib.getSecretPath "identities.nix");
  pubKey = identities.${cfg.user}.agentSigningKey;
in
{
  options.custom.profiles.agent-signing = {
    enable = lib.mkEnableOption ''
      the dedicated non-admin agent commit-signing key in a user's ~/.ssh, so that a
      headless seat running agent sessions can sign the commits it is asked to produce
      (ADR-0003). Enable only on a host listed as a recipient of users/<user>.yaml
    '';

    user = lib.mkOption {
      type = lib.types.str;
      default = "inkpotmonkey";
      description = ''
        The account whose `~/.ssh/id_ed25519{,.pub}` is written. Must match the account the
        agent runs as — `custom.profiles.opencode.user` on a host running opencode — or the
        key lands in a home the agent never reads.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.agent_signing_key = {
      sopsFile = self.lib.getSecretPath "users/${cfg.user}.yaml";
      key = "signing_key";
      owner = cfg.user;
      mode = "0400";
    };

    # ── PLACED AS A SYMLINK INTO /run/secrets, DECLARED FROM `.ssh` DOWN ──────────────────
    # The same shape profiles/forge-client.nix uses for `~/.config/tea/config.yml`, and for
    # the same reason: on an impermanence host the home is a tmpfs and anything written into
    # it at activation is gone at the next boot. `L+` replaces whatever is at the path, which
    # makes this self-healing rather than something that needs a persistence entry.
    #
    # `.ssh` itself is declared with its owner because systemd-tmpfiles creates missing
    # PARENTS as root — leaving it undeclared risks a root-owned `~/.ssh` on whichever boot
    # tmpfiles gets there first, which breaks far more than this module.
    #
    # ⚠ THE `.pub` IS A REAL FILE, NOT A SYMLINK INTO THE STORE, and it must sit beside the
    # private key under exactly this name. `ssh-keygen -Y sign` strips the `.pub` from
    # `signing.key` and opens the sibling path; git.nix chose the path form precisely so that
    # signing works with no agent loaded. A `.pub` anywhere else means the private half has
    # no sibling and every commit fails the way it does today.
    systemd.tmpfiles.settings."10-agent-signing" = {
      "${sshDir}".d = {
        inherit (cfg) user;
        group = "users";
        mode = "0700";
      };
      "${sshDir}/id_ed25519"."L+" = {
        inherit (cfg) user;
        group = "users";
        mode = "0400";
        argument = config.sops.secrets.agent_signing_key.path;
      };
      "${sshDir}/id_ed25519.pub".f = {
        inherit (cfg) user;
        group = "users";
        mode = "0444";
        argument = pubKey;
      };
    };
  };
}
