{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.property-watch;
in
{
  options.custom.profiles.property-watch = {
    enable = lib.mkEnableOption "the property-watch agent job's state tree and source script";

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/property-watch";
      description = "Shared tree the job writes and the board (property#5) reads.";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── THE SHARING GROUP ────────────────────────────────────────────────────────────
    # Same shape as `music` (ADR-0028) and `library`: one writer OWNS the tree, everyone
    # else reaches it through a group whose GID is PINNED. The pin is not decoration —
    # this tree lives on persistent storage, and an auto-allocated GID reshuffle orphans
    # every file's group in place (this fleet has been bitten by exactly that; see
    # [[kelpy-uid-map-drift]]).
    #
    # Registry of pins at hosts/rk1/library.nix: opencode=975, hermes=976, library=977,
    # music=978, stump=979, stalwart-mail=981, supernote=982, git-annex=987, forgejo=997.
    #
    # ⚠ NOT 974, which LOOKS free on main but is not: the unmerged finance branch pins
    # `financeGid = 974` (modules/nixos/profiles/finance/default.nix). `nix flake check`
    # would not catch that until the day finance merges, and the symptom then is a tree
    # whose group ownership silently belongs to another service. 973 is unclaimed by any
    # branch in this repo.
    users.groups.property-watch.gid = 973;

    # hermes writes the database; the board (property#5) will join this group to read it.
    users.users.hermes.extraGroups = [ "property-watch" ];

    # 2770: setgid, so anything any member creates inherits the group rather than the
    # creator's primary one. Without it the board's first write lands owned by the board
    # alone and the job silently stops being able to read favourites.
    #
    # Owned by the human, not by hermes: config.json and AGENTS.md are the buying brief,
    # and the agent must be able to READ them and unable to REWRITE them. If hermes could
    # edit the criteria, the job could drift what it shows you and the only evidence would
    # be listings that quietly stopped appearing. Ownership enforces that, not policy.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 2770 inkpotmonkey property-watch - -"
    ];

    # For opening the database by hand over ssh. Deliberately NOT added to hermes's
    # `extraPackages`: the agent has no business shelling out to a database it should be
    # reading through its source script's output, and that PATH is narrow on purpose.
    environment.systemPackages = [ pkgs.sqlite ];

    # ── THE SOURCE SCRIPT, DECLARED ──────────────────────────────────────────────────
    # A source script is mutable by default so the agent can improve it. This one is
    # declared because its job writes OUTSIDE hermes's own state — into a shared tree a
    # second service reads — which is the line `docs/agents/agent-jobs.md` draws. Declaring
    # means activation overwrites, which is the point: review and rollback.
    #
    # ⚠ hermes resolves `--script` only inside $HERMES_HOME/scripts/, and a store SYMLINK
    # fails its escape guard — so `hermesHomeFiles` COPIES the file there. Editing it on the
    # host is therefore pointless: the next activation puts this version back.
    services.hermes-agent.hermesHomeFiles."scripts/property-watch.py" = ./property-watch.py;
  };
}
