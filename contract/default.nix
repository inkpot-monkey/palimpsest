# The shared host↔user contract (ADR-0015): the schema both host and user agree
# on — identity, home-profile meta, and the feature/grant vocabulary that denial
# keys on. Exposed on `self.contract` so both the system and home evaluations
# consume one source. In-repo it is a shared module set; at the repo split
# (slice 07) it becomes a real flake input — a URL change, not a re-wire.
# Tracked: .scratch/host-user-contract/.
{
  flake.contract = {
    identity = ./identity.nix;
    homeProfiles = ./home-profiles.nix;
    features = ./features.nix;
  };
}
