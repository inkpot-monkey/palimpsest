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
  contradictory = variant {
    notBackedUp = realJob.notBackedUp // {
      "/var/lib/supernote" = "but it IS backed up, a few lines up";
    };
  };

  claims = [
    {
      name = "the real fleet passes: no host trips a targeting rule";
      ok = lib.all (
        h:
        !(lib.any (r: lib.hasInfix r (lib.concatStringsSep "\n" (failures h.config))) (
          lib.attrValues rules
        ))
      ) (lib.attrValues self.nixosConfigurations);
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
      # Targeting is only safe if the thing it protects is still named. rk1b carries the
      # fleet's only live job, and these are the trees palimpsest#150 exists for.
      name = "rk1b still names the photo library, the document library and the Supernote store";
      ok = lib.all (x: lib.elem x realJob.paths) [
        "/var/cache/immich/upload"
        "/var/cache/immich/backups"
        "/var/cache/library"
        "/persistent/var/lib/supernote"
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
