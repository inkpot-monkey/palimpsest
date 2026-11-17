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

    # TWO directories, and the split is the whole point.
    #
    # The top level holds the buying brief -- config.json and AGENTS.md -- and is 2750:
    # the group may read and traverse, and may NOT write. A single 2770 tree was the
    # obvious shape and is wrong: group-write on a DIRECTORY lets a member unlink and
    # replace a file inside it whatever that file's own mode says, so hermes could have
    # rewritten the criteria by deleting them. The agent must be able to READ the brief
    # and unable to REWRITE it -- if it could, the job would drift what it shows you and
    # the only evidence would be listings that quietly stopped appearing.
    #
    # `data/` is where the job actually writes, and is 2770 hermes-owned. setgid so that
    # anything any member creates inherits `property-watch` rather than the creator's own
    # primary group -- without it the board's first write to `favourites` lands owned by
    # the board alone and the job silently stops being able to read it.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 2750 inkpotmonkey property-watch - -"
      "d ${cfg.stateDir}/data 2770 hermes property-watch - -"
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
