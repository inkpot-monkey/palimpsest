{
  self,
  pkgs,
  inputs,
  ...
}:

# The TARGETING RULES for off-site backups (ADR-0036): enumerate what is irreplaceable, never
# snapshot a machine, and classify every directory the host persists.
#
# Two of those three are module assertions, which means `nix flake check` already fails if a
# real host breaks them — so this check exists for the other direction, which nothing else
# covers: that the rules still REJECT the configurations they were written to reject. An
# assertion whose condition quietly became unfalsifiable passes every build forever and reads
# exactly like a working guard. The only way to know is to hand it a bad config.
#
# No VM. The subject is eval-time, so each case extends a REAL host (rk1b, the one host with a
# live off-site job) with a deliberately-wrong job and reads back `config.assertions` —
# evaluating the booleans without building the toplevel the failing ones would abort. Extending
# a real host rather than stubbing one keeps the cases honest: they run against the same
# profile, secrets and impermanence declaration the fleet actually has.

let
  inherit (pkgs) lib;

  host = self.nixosConfigurations.rk1b;

  # The assertions this file is about, identified by a distinctive phrase from each message.
  # Matching on the message rather than an index means re-ordering the list cannot silently
  # retarget a case at a different assertion.
  rules = {
    bulk = "whole-machine root";
    unclassified = "neither backed up nor declined";
    stale = "no longer persists";
    contradictory = "both backed up and listed";
  };

  # Every FAILING assertion of an evaluated host, as messages.
  failures = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);

  fires = rule: cfg: lib.any (m: lib.hasInfix rules.${rule} m) (failures cfg);

  # A variant of rk1b whose `daily` job is replaced wholesale. mkForce throughout: `paths` and
  # `notBackedUp` merge by concatenation and union, so a plain definition would ADD to the real
  # host's enumeration instead of standing in for it, and every case would quietly pass.
  variant =
    job:
    (host.extendModules {
      modules = [ { custom.profiles.backup.jobs.daily = lib.mapAttrs (_: lib.mkForce) job; } ];
    }).config;

  # The real host, untouched.
  real = host.config;
  realJob = real.custom.profiles.backup.jobs.daily;

  # 1. A bulk root must be refused, however it is spelled.
  bulkPersistent = variant { paths = [ "/persistent" ]; };
  bulkTrailingSlash = variant { paths = [ "/var/lib/" ]; };
  bulkHome = variant { paths = [ "/home" ]; };

  # 2. A persisted directory that is neither backed up nor declined must be refused. Forcing
  #    `notBackedUp` empty leaves rk1b's fourteen declined directories unclassified.
  unclassified = variant { notBackedUp = { }; };

  # 3. ...and the list cannot rot: a declined directory the host no longer persists is refused,
  #    so the file keeps describing the machine that exists.
  stale = variant {
    notBackedUp = realJob.notBackedUp // {
      "/var/lib/a-service-that-moved-to-another-host" = "left behind by a migration";
    };
  };

  # 4. ...and it cannot contradict itself.
  # Self-contained on purpose: rk1b backs up nothing under its impermanence root any more
  # (its trees are on the NVMe), so a contradiction has to be constructed from both sides
  # rather than borrowed from the real job.
  contradictory = variant {
    paths = [ "/persistent/var/log" ];
    inherit (realJob) notBackedUp;
  };

  # ── THE FLEET-WIDE HALF ─────────────────────────────────────────────────────────────────
  # Three properties that no single host can check, which is why they went unchecked. The
  # module's own staggering assertion compares a host's DESTINATIONS against each other and
  # never the fleet's HOSTS against each other; the runtime untagged-snapshot probe
  # (modules/nixos/profiles/restic-untagged-snapshots.nix) says in its own comment that the
  # wider invariant "a host cannot see" belongs somewhere with the whole fleet in view. This
  # is that somewhere: `self.nixosConfigurations` is right here, and a check is not part of
  # any host's config, so reading every host from it cannot recurse.

  fleet = lib.attrValues self.nixosConfigurations;

  # Every (host, job, destination) that actually writes snapshots, fleet-wide.
  writers = lib.concatMap (
    h:
    let
      c = h.config;
      b = c.custom.profiles.backup;
      enabledJob =
        n:
        if n == "daily" then
          b.enable
        else if n == "telemetry" then
          b.monitoringTelemetry.enable
        else
          false;
    in
    lib.concatLists (
      lib.mapAttrsToList (
        jobName: job:
        lib.mapAttrsToList (destName: dest: {
          inherit
            jobName
            destName
            job
            dest
            ;
          host = c.networking.hostName;
          cfg = c;
        }) (lib.filterAttrs (_: d: d.enable) b.destinations)
      ) (lib.filterAttrs (n: _: enabledJob n) b.jobs)
    )
  ) fleet;

  # 1. Exactly one maintainer per destination. `prune` and `check` rewrite and read the whole
  #    repository, so two maintainers repack the same packs and download the same tenth twice
  #    while fighting one exclusive lock — and ZERO maintainers means nothing ever verifies
  #    the copy at all, which is the failure phase 0 existed to end. `maintenance` defaults to
  #    false precisely so the second case is the accident, and only a fleet-wide view can
  #    tell the two apart.
  maintainersOf =
    ws: destName:
    lib.unique (map (w: w.host) (lib.filter (w: w.destName == destName && w.dest.maintenance) ws));

  # Destinations in use, for an arbitrary fleet.
  destinationsOf = ws: lib.unique (map (w: w.destName) ws);

  oneMaintainerEach = ws: lib.all (d: lib.length (maintainersOf ws d) == 1) (destinationsOf ws);

  # 2. Minute-of-day for the OnCalendar shapes this fleet uses ("03,15:00", "Sun 03:30").
  #    Returns null for anything else rather than guessing, so an unparsed calendar FAILS the
  #    claim by name instead of passing it silently — the mistake the narrow first version of
  #    the no-failing-assertion claim above made.
  calendarMinutes =
    s:
    let
      timePart = lib.last (lib.splitString " " s);
      parts = lib.splitString ":" timePart;
      hourTokens = lib.splitString "," (lib.head parts);
      numeric =
        t:
        t != "" && lib.all (c: lib.elem c (lib.stringToCharacters "0123456789")) (lib.stringToCharacters t);
    in
    if lib.length parts != 2 || !(numeric (lib.elemAt parts 1)) || !(lib.all numeric hourTokens) then
      null
    else
      # toIntBase10, not toInt: "03" is zero-padded here and `toInt` refuses it as ambiguous
      # between octal and decimal, which would make every calendar unparseable.
      map (h: lib.toIntBase10 h * 60 + lib.toIntBase10 (lib.elemAt parts 1)) hourTokens;

  # A backup unit CANNOT wait for a lock — `--retry-lock` is unreachable through the nixpkgs
  # module (extraOptions is `-o`-prefixed, extraBackupArgs reaches only `backup`;
  # nixpkgs#468191) — so a backup that starts while ANY host holds the repository's exclusive
  # lock simply fails. forget and prune take that lock. Schedule separation is therefore the
  # only mitigation available, and it has to hold across hosts, not within one.
  backupStarts =
    ws:
    lib.concatMap (
      w:
      let
        cal = (w.job.timerConfig // (w.dest.settings.timerConfig or { })).OnCalendar or null;
        m = if cal == null then null else calendarMinutes cal;
      in
      [
        {
          inherit (w) host destName;
          what = "backup ${w.jobName}";
          calendar = cal;
          minutes = m;
        }
      ]
    ) ws;

  exclusiveStarts =
    ws:
    lib.concatMap (
      w:
      map
        (k: {
          inherit (w) host destName;
          inherit (k) what;
          calendar = k.cal;
          minutes = if k.cal == null then null else calendarMinutes k.cal;
        })
        (
          [
            {
              what = "forget ${w.jobName}";
              cal = w.dest.forgetCalendar;
            }
          ]
          ++ lib.optional w.dest.maintenance {
            what = "prune";
            cal = w.dest.pruneCalendar;
          }
        )
    ) ws;

  # 20 minutes. Not arbitrary: the fleet's largest backup reads 13 GiB and finishes in about
  # three (measured on rk1b), and `forget` carries RandomizedDelaySec = 20m, so a gap below
  # this is a window in which a randomised maintenance start can land on a running backup.
  minGapMinutes = 20;

  tooClose =
    ws:
    lib.concatMap (
      b:
      lib.concatMap (
        e:
        lib.optional (
          b.destName == e.destName
          && b.minutes != null
          && e.minutes != null
          && lib.any (
            bm: lib.any (em: bm - em < minGapMinutes && em - bm < minGapMinutes) e.minutes
          ) b.minutes
        ) "${b.host} ${b.what} (${b.calendar}) vs ${e.host} ${e.what} (${e.calendar})"
      ) (exclusiveStarts ws)
    ) (backupStarts ws);

  unparsedCalendars =
    ws:
    lib.unique (
      map (x: "${x.host} ${x.what}: ${toString x.calendar}") (
        lib.filter (x: x.minutes == null) (backupStarts ws ++ exclusiveStarts ws)
      )
    );

  # 3. Every (host, tag) pair that writes snapshots is governed by a forget unit on that host
  #    whose scope matches it — the config-side twin of the runtime untagged probe. Untagged
  #    snapshots were the case that actually happened; this is the neighbouring one, where a
  #    snapshot carries a tag that no retention policy on the fleet selects for.
  ungoverned =
    ws:
    lib.concatMap (
      w:
      let
        unit = w.cfg.systemd.services."restic-forget-${w.jobName}-${w.destName}" or null;
        execStart = if unit == null then "" else toString (unit.serviceConfig.ExecStart or [ ]);
        scoped = lib.hasInfix "--host ${w.host}" execStart && lib.hasInfix "--tag ${w.jobName}" execStart;
      in
      lib.optional (unit == null || !scoped || w.job.retention == [ ]) (
        "${w.host} ${w.jobName}@${w.destName}"
        + (
          if unit == null then
            " (no forget unit)"
          else if !scoped then
            " (forget not scoped to it)"
          else
            " (empty retention policy)"
        )
      )
    ) ws;

  # ── SYNTHETIC FLEETS, so the three claims above are falsifiable ──────────────────────────
  # The real fleet passing proves nothing on its own: a predicate that cannot fail reads
  # exactly like one that holds. Each of these is the smallest fleet that breaks one rule.
  w =
    {
      host,
      job ? "daily",
      dest ? "rsyncnet",
      maintenance ? false,
      backupCal ? "03,15:00",
      forgetCal ? "Sun 03:30",
      pruneCal ? "Sun 04:00",
      retention ? [ "--keep-daily 7" ],
      forgetUnit ? "default",
    }:
    {
      jobName = job;
      destName = dest;
      inherit host;
      job = {
        inherit retention;
        timerConfig.OnCalendar = backupCal;
      };
      dest = {
        inherit maintenance;
        forgetCalendar = forgetCal;
        pruneCalendar = pruneCal;
        settings = { };
      };
      cfg.systemd.services = lib.optionalAttrs (forgetUnit != "missing") {
        "restic-forget-${job}-${dest}".serviceConfig.ExecStart = [
          (
            if forgetUnit == "unscoped" then
              "restic forget --tag ${job} --keep-daily 7"
            else
              "restic forget --host ${host} --tag ${job} --keep-daily 7"
          )
        ];
      };
    };

  twoMaintainers = [
    (w {
      host = "rk1b";
      maintenance = true;
    })
    (w {
      host = "kelpy";
      maintenance = true;
    })
  ];
  noMaintainer = [ (w { host = "rk1b"; }) ];
  backupOnTopOfForget = [
    (w {
      host = "rk1b";
      maintenance = true;
      backupCal = "03,15:00";
      forgetCal = "Sun 03:10";
    })
  ];
  # Each host is individually fine — rk1b backs up at 06:00, 165 minutes clear of its own
  # 03:15 forget; kelpy's own forget is at 09:00, six hours from its backups. The collision
  # exists only BETWEEN them, on the repository they share, which is the whole point: no
  # single host's evaluation can see it.
  crossHostCollision = [
    (w {
      host = "rk1b";
      maintenance = true;
      backupCal = "06:00";
      forgetCal = "Sun 03:15";
    })
    (w {
      host = "kelpy";
      backupCal = "03,15:00";
      forgetCal = "Sun 09:00";
    })
  ];
  unparsable = [
    (w {
      host = "rk1b";
      maintenance = true;
      backupCal = "00/6:00";
    })
  ];
  missingForget = [
    (w {
      host = "rk1b";
      forgetUnit = "missing";
    })
  ];
  unscopedForget = [
    (w {
      host = "rk1b";
      forgetUnit = "unscoped";
    })
  ];
  emptyRetention = [
    (w {
      host = "rk1b";
      retention = [ ];
    })
  ];

  claims = [
    {
      # ANY failing assertion, not just the targeting ones. The narrower version of this
      # claim passed while rk1b was in fact broken: an earlier draft of its job added
      # /var/lib/supernote, which custom.profiles.supernote forbids (ADR-0031), and a check
      # looking only for its own four messages never saw it — `just deploy` did. A real host
      # with any failing assertion cannot be deployed, so there is no reason to be selective.
      name = "every real host evaluates with no failing assertion at all";
      ok = lib.all (h: failures h.config == [ ]) (lib.attrValues self.nixosConfigurations);
    }
    {
      name = "rk1b's own enumeration classifies every directory it persists";
      ok = !(fires "unclassified" real) && !(fires "stale" real) && !(fires "contradictory" real);
    }
    {
      # The rule the instruction "we shouldn't just bulk backup machines" turns into.
      name = "paths = [ /persistent ] is REFUSED (a machine snapshot, not a backup)";
      ok = fires "bulk" bulkPersistent;
    }
    {
      # A trailing slash is the same path; a naive `elem` would miss it.
      name = "paths = [ /var/lib/ ] is REFUSED despite the trailing slash";
      ok = fires "bulk" bulkTrailingSlash;
    }
    {
      name = "paths = [ /home ] is REFUSED (143 GiB of it on the workstation)";
      ok = fires "bulk" bulkHome;
    }
    {
      # The failure mode that makes enumeration dangerous: a service persists state and
      # nobody notices it is unprotected. This is the assertion that turns that into a build
      # failure, and this is the case proving it still can.
      name = "an unclassified persisted directory is REFUSED";
      ok = fires "unclassified" unclassified;
    }
    {
      name = "a notBackedUp entry the host no longer persists is REFUSED (the list cannot rot)";
      ok = fires "stale" stale;
    }
    {
      name = "a directory both backed up and declined is REFUSED";
      ok = fires "contradictory" contradictory;
    }
    {
      # Needs the whole fleet: a host sees only its own `maintenance` flag, so neither "two
      # hosts both maintaining one repository" nor "nobody maintaining it" is visible from
      # inside a host's own evaluation.
      name = "exactly one host maintains each destination in use (${lib.concatStringsSep ", " (destinationsOf writers)})";
      ok = oneMaintainerEach writers;
    }
    {
      name = "no backup starts within ${toString minGapMinutes} minutes of any host's exclusive-lock operation on the same repository";
      ok = tooClose writers == [ ];
    }
    {
      # A calendar this parser does not understand must fail loudly; the claim above is
      # worthless if an unrecognised string quietly counts as "no collision".
      name = "every backup and maintenance calendar in the fleet is one this check can actually compare";
      ok = unparsedCalendars writers == [ ];
    }
    {
      # The wider invariant the untagged-snapshot probe deliberately deferred to a
      # fleet-wide view: not just "does every snapshot carry a tag" but "is every tag the
      # fleet writes governed by a retention policy that selects for it".
      name = "every (host, tag) the fleet writes is governed by a scoped forget unit with a non-empty policy";
      ok = ungoverned writers == [ ];
    }
    {
      name = "TWO hosts maintaining one repository is REFUSED (duplicate prune, one lock)";
      ok = !(oneMaintainerEach twoMaintainers);
    }
    {
      name = "ZERO hosts maintaining a repository in use is REFUSED (nothing ever verifies it)";
      ok = !(oneMaintainerEach noMaintainer);
    }
    {
      name = "a backup 20 minutes before its own host's forget is REFUSED";
      ok = tooClose backupOnTopOfForget != [ ];
    }
    {
      # The gap only a fleet-wide view can see: each host is individually well spaced, and
      # kelpy's backup still lands inside rk1b's forget window on the shared repository.
      name = "a backup landing in ANOTHER host's forget window is REFUSED";
      ok = tooClose crossHostCollision != [ ];
    }
    {
      name = "a calendar this check cannot parse is REFUSED, not silently passed";
      ok = unparsedCalendars unparsable != [ ];
    }
    {
      name = "a job with no forget unit at all is REFUSED";
      ok = ungoverned missingForget != [ ];
    }
    {
      name = "a forget unit not scoped to the host that wrote the snapshots is REFUSED";
      ok = ungoverned unscopedForget != [ ];
    }
    {
      name = "a job whose retention policy is empty is REFUSED (forget would select nothing)";
      ok = ungoverned emptyRetention != [ ];
    }
    {
      # Targeting is only safe if the thing it protects is still named. rk1b carries the
      # fleet's only live job, and these are the trees palimpsest#150 exists for.
      name = "rk1b still names the photo library and the document library";
      ok = lib.all (x: lib.elem x realJob.paths) [
        "/var/cache/immich/upload"
        "/var/cache/immich/backups"
        "/var/cache/library"
      ];
    }
  ];
in
inputs.contract.lib.mkClaimReport {
  inherit pkgs;
  name = "backup-targeting";
  title = "off-site backups are targeted, and the rules still reject a machine snapshot (ADR-0036)";
  inherit claims;
}
