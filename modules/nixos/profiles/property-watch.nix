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

    jobId = {
      enable = lib.mkEnableOption ''
        the check that this job's judgement is still reaching the database. Needs the
        hermes job id, which is imperative state (`hermes cron list`) and not knowable
        from the flake -- so it is passed in rather than derived
      '';
      jobId = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "The hermes cron job id, from `hermes cron list`.";
      };
    };

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

    # And the operator, who otherwise cannot read the data directory hermes owns -- which
    # also made putting sqlite3 on the system PATH below pointless, since the one database
    # it exists to open sits in there. Found by checking after the first real run, not by
    # reading the module back.
    users.users.inkpotmonkey.extraGroups = [ "property-watch" ];

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

    # ── AND THE SANDBOX HAS TO AGREE ─────────────────────────────────────────────────
    # hermes-agent runs ProtectSystem=strict with ReadWritePaths=/var/lib/hermes, so the
    # whole of this tree is READ-ONLY to the service however the file modes read. Without
    # this the job fails at `PRAGMA journal_mode=WAL` with "unable to open database file",
    # which looks like a permissions bug and is not one — and does NOT reproduce under
    # `sudo -u hermes`, because that has no sandbox. Only the service does.
    #
    # Note what is granted: data/ alone. The brief at the root stays read-only to hermes
    # at the systemd layer too, so the split is enforced twice over — once by ownership,
    # once by the sandbox — and neither depends on the other being right.
    systemd.services.hermes-agent.serviceConfig.ReadWritePaths = [ "${cfg.stateDir}/data" ];

    # ── THE SILENT FAILURE THIS JOB HAS ──────────────────────────────────────────────
    # property#7. The model's judgement reaches the corpus by the model writing a file and
    # calling `--apply-verdicts`. If that stops working -- a prompt edit, a model that stops
    # following it, a permissions change -- the DAILY MESSAGE STILL ARRIVES AND STILL LOOKS
    # RIGHT. hermes reports the run completed, `--failure-deliver` has nothing to say, and
    # the only symptom is a board whose verdicts quietly stop moving, which nobody notices
    # until they go looking for one.
    #
    # Declared HERE, not in the watcher: the assertion is about this job's schema, and a
    # fleet-generic watcher that knew about `verdicts` would collect a clause per job.
    custom.profiles.monitoring-hermes-overdue.producedChecks = lib.mkIf cfg.jobId.enable {
      property-verdicts = {
        inherit (cfg.jobId) jobId;
        db = "${cfg.stateDir}/data/property-watch.db";
        sql = "SELECT COUNT(*) FROM verdicts WHERE judged_on = date('now')";
        message = "left no verdicts; its judgement is no longer reaching the corpus";
      };
    };

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
    # ⚠ THE JOB POINTS AT THE .sh, NOT THE .py. Handed a `.py`, hermes runs it through a
    # "dependency environment" interpreter inside its own package
    # (.../site-packages/venv/bin/python) which does not exist on NixOS — the run fails
    # with "dependency environment interpreter is missing" before the script is reached.
    # `.sh` is dispatched to bash instead, which works.
    #
    # The wrapper carries ${pkgs.python3} from the flake rather than the job carrying a
    # /nix/store path in `--interpreter`, so the interpreter is renewed by every rebuild
    # instead of going stale the first time hermes is upgraded. The BARE interpreter is
    # deliberately sufficient: property-watch.py imports nothing outside the standard
    # library, which is what keeps it runnable in an environment with almost no packages.
    #
    # ⚠ THE CORPUS RECORDED BEFORE property#6 HAS NO PROSE. Detail pages are fetched for newly
    # seen listings only, so the ~275 listings already in the database when descriptions started
    # being collected have none and will never acquire any on their own. Drain that backlog by
    # hand, a bounded number of requests at a time — it prints nothing on stdout, so it cannot
    # be mistaken for something moving:
    #
    # ⚠ `hermesHomeFiles` installs mode 0640 — NOT executable — so the wrapper cannot be run
    # directly however correct the path is ("command not found", which reads like a missing
    # file). hermes itself dispatches it through bash, so the JOB is unaffected; an operator
    # running it by hand has to say bash explicitly:
    #
    #   sudo -u hermes -H bash /var/lib/hermes/.hermes/scripts/property-watch.sh --backfill 40 --verbose
    #
    # At CRAWL_DELAY that is roughly a minute per 40. Run it a few times, not once with 300.
    services.hermes-agent.hermesHomeFiles = {
      "scripts/property-watch.py" = ./property-watch.py;
      "scripts/property-watch.sh" = pkgs.writeShellScript "property-watch-wrapper" ''
        exec ${pkgs.python3}/bin/python3 "$(dirname "$0")/property-watch.py" "$@"
      '';
    };
  };
}
