# The agent's client side of the private forge — palimpsest#204, ticket #213, phase 2 of the
# credential design settled in #209.
#
# What it buys: on a host with this enabled, `tea` and `tea api` are on PATH with a default
# login already configured, so NO recipe in the tracker doc (#210) has to carry a token, a
# URL or a login name. An agent running as the operator account just runs `tea`.
#
# Enabled on exactly two hosts and deliberately NOT fleet-wide — see `secretFile` for the
# sops trap that makes that mandatory rather than tidy:
#   * kelpy          — runs the forge, and runs agent sessions as the operator account
#   * sawtoothShark  — the workstation the agent is usually driven from
#
# ── Why this is host config and not part of the operator's home ───────────────────────────
# Settled in #209 against three stale premises, all three worth not re-discovering:
#   * home-sops has been DISMANTLED fleet-wide. `~/code/users` provisions no secrets and
#     forbids re-wiring any of it piecemeal, so a "user-scoped" secret here simply IS a host
#     sops secret. The live precedent is `github_token` in profiles/nixConfig.nix, whose own
#     comment says it exists because headless things on kelpy "run as the user but have no
#     user session, and thus no home-manager sops secrets".
#   * pre-built homes are built per MODE, not per host (the contract hardcodes
#     `exposed = false` in a home's hostFacts because which seat binds it is unknowable
#     there), so a home CANNOT differ per host. Per-host tokens have to live host-side.
#   * `contract.exposed` enforces nothing — it is a posture record, not a gate. There was no
#     refusal to work around.
#
# ── Why the login is RENDERED and `tea logins add` is never run ───────────────────────────
# `tea` reads $XDG_CONFIG_HOME/tea/config.yml and no subcommand accepts a token
# per-invocation (#206), so the file has to exist. The decider against writing it with
# `tea logins add` was kelpy's impermanence: it wipes the tmpfs root and persists only
# `.claude` and `code`, so anything `tea` writes into ~/.config is destroyed at every
# reboot. That path would need a persistence entry AND a re-run trigger just to survive a
# restart; the rendered file is self-healing by construction, and rotation is "edit the
# secret, deploy".
{
  config,
  lib,
  pkgs,
  self,
  settings,
  ...
}:
let
  cfg = config.custom.profiles.forge-client;

  home = config.users.users.${cfg.localUser}.home;
  teaDir = "${home}/.config/tea";
in
{
  options.custom.profiles.forge-client = {
    enable = lib.mkEnableOption ''
      the `tea` client for the private forge, with a declaratively rendered login
      (palimpsest#213). Enable only on a host listed as a recipient of the forgejo sops
      file — see the `secretFile` option
    '';

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://forge.${settings.primaryDomain}";
      defaultText = lib.literalExpression ''"https://forge.''${settings.primaryDomain}"'';
      description = ''
        The forge's public base URL. Derived the same way profiles/forge.nix derives
        `ROOT_URL`, from the `forge` entry in the service registry whose attribute name IS
        the vhost subdomain — so the two cannot drift.

        Reached over the tailnet: the vhost sits behind Caddy's `internal_only` guard, which
        is the whole of the access control on it.
      '';
    };

    loginName = lib.mkOption {
      type = lib.types.str;
      default = "forge";
      description = ''
        The login's name in `tea`'s config — what `tea --login <name>` would take. Only one
        login is ever rendered and it is the default, so no recipe needs to name it.
      '';
    };

    localUser = lib.mkOption {
      type = lib.types.str;
      default = "inkpotmonkey";
      description = ''
        The UNIX account whose `~/.config/tea/config.yml` is rendered. The rendered file is
        owned by this user at mode 0400, so only this account (and root) can read the token.
      '';
    };

    forgeUser = lib.mkOption {
      type = lib.types.str;
      default = cfg.localUser;
      defaultText = lib.literalExpression "config.custom.profiles.forge-client.localUser";
      description = ''
        The account the token belongs to ON THE FORGE. Separate from `localUser` because
        nothing guarantees they match; they do here, and the forge has exactly one account
        (profiles/forge.nix `adminUser`).

        `tea` only uses this for display and for building `@user` links — the token alone
        decides what the API lets through — so a wrong value here is cosmetic, not a
        permission bug.
      '';
    };

    tokenKey = lib.mkOption {
      type = lib.types.str;
      default = "forgejo/token_${config.networking.hostName}";
      defaultText = lib.literalExpression ''"forgejo/token_''${config.networking.hostName}"'';
      description = ''
        Key in the sops file holding this host's Forgejo access token.

        PER HOST, not shared: Forgejo names tokens, so minting one per host buys independent
        revocation for the cost of one extra key (#209). The token is created by
        `forgejo admin user generate-access-token` on kelpy — which takes no password, so
        minting needs no credential beyond shell access as the forgejo user.

        ⚠ Adding a third host means a new key here AND a new recipient on the sops file.
        Both, or that host installs none of its secrets — see `secretFile`.

        ⚠ Store it as a PLAIN YAML SCALAR. A block scalar (`|`) appends a newline to the
        value; the rendered file is shaped to absorb that (see profiles/tea-login.nix) but
        nothing else that reads this key would be.
      '';
    };

    secretFile = lib.mkOption {
      type = lib.types.path;
      default = self.lib.getSecretFile "forgejo";
      defaultText = lib.literalExpression ''self.lib.getSecretFile "forgejo"'';
      description = ''
        sops file holding the per-host tokens, alongside the forge admin password that
        profiles/forge.nix reads.

        ⚠ Its recipients are `&admin, &kelpy, &sawtoothShark` — three of the fleet's seven,
        because only two machines have any business talking to the forge. sops grants per
        FILE, not per key, so ANY reference to it must be host-scoped. This whole block sits
        inside `mkIf cfg.enable` for that reason: a fleet-wide declaration would ask a host
        that cannot decrypt this file to install it, and `sops-install-secrets` is
        ALL-OR-NOTHING per host — that host would then install NONE of its secrets, which on
        a Pi means no wifi (AGENTS.md).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.users.users ? ${cfg.localUser};
        message = "custom.profiles.forge-client.localUser is set to '${cfg.localUser}', which is not an account on ${config.networking.hostName}. The rendered login is owned by that user and placed in its home, so both would fail at activation.";
      }
      {
        # Without sops there is no secret and no template — the module would silently
        # produce a config.yml whose token is the literal placeholder string, and every
        # `tea` call would come back 401 with nothing pointing at the cause.
        assertion = config.custom.profiles.sops.enable;
        message = "custom.profiles.forge-client requires custom.profiles.sops — the forge token is a sops secret and the login is a sops template.";
      }
    ];

    # `tea` from the HOST, not the pre-built home. kelpy binds the cli home and
    # sawtoothShark the gui one, so a home-side `tea` would have to go in the users repo's
    # `common.nix`, whose stated test is "would a home built for the floor still be honest
    # carrying it?" — dragging a forge CLI onto every headless seat, and costing a
    # users-repo commit plus `nix flake update users` per change (#209).
    environment.systemPackages = [
      pkgs.tea
      # NOT incidental. `tea` shells out to `git rev-parse --show-toplevel` on EVERY
      # invocation to discover repository context, including commands that need none —
      # without git on PATH, `tea repos ls` does not degrade, it exits 1 with
      #   Error: git rev-parse --show-toplevel: exec: "git": executable file not found
      # (measured while writing parts/checks/forge-client, which is where that line is
      # pinned). Both hosts happen to carry git already; declared here so the dependency
      # belongs to this profile rather than to a coincidence.
      pkgs.git
    ];

    sops.secrets.forge_token = {
      sopsFile = cfg.secretFile;
      key = cfg.tokenKey;
      # Read only by sops-nix itself, to render the template below. Nothing else needs the
      # bare token, so unlike `github_token` this is NOT group-readable: the group-read
      # there exists so the user's git credential helper can read it directly, and the
      # equivalent here is the rendered config.yml, which carries its own owner.
      mode = "0400";
    };

    sops.templates."tea-config" = {
      content = import ./tea-login.nix {
        inherit (cfg) loginName url;
        user = cfg.forgeUser;
        token = config.sops.placeholder.forge_token;
      };
      owner = cfg.localUser;
      mode = "0400";
    };

    # ── The login, placed in the home as a SYMLINK into /run/secrets ──────────────────────
    # Declared from `.config` down, each level with the owner it must have. This is not
    # defensive padding: on kelpy the home is tmpfs and `~/.config` is recreated at every
    # boot, and systemd-tmpfiles creates missing PARENTS as root — so leaving `.config`
    # undeclared risks a root-owned `~/.config` on whichever boot tmpfiles gets there first,
    # which would break home-manager activation rather than just this module.
    #
    # `L+` replaces whatever is at the path, which makes the login self-healing and is the
    # whole point of rendering it. The corollary is that `tea logins add` / `logins edit` on
    # these hosts is TRANSIENT — it writes a real file that the next deploy or boot throws
    # away. Change the secret, not the file.
    systemd.tmpfiles.rules = [
      "d ${home}/.config 0755 ${cfg.localUser} ${config.users.users.${cfg.localUser}.group} -"
      "d ${teaDir} 0700 ${cfg.localUser} ${config.users.users.${cfg.localUser}.group} -"
      "L+ ${teaDir}/config.yml - - - - ${config.sops.templates."tea-config".path}"
    ];
  };
}
