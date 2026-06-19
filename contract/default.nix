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
    # User-owned feature *configuration* (parameters of a feature), distinct from
    # the host-owned grant. Host-affecting params (e.g. gui.session) aggregate as a
    # union across granted users — ADR-0016.
    featureConfig = ./feature-config.nix;
    platform = ./platform.nix;
    # Host-invariant module mapping custom.users.<u> to system accounts.
    realization = ./realization.nix;
    # The gui feature module: host effects of the gui grant (uinput, the emacs
    # overlay), gated on any gui grant. Imported alongside the realization so a user
    # never writes them (ADR-0018, slice 10).
    guiFeature = ./features/gui.nix;
    # Static metadata about features (not options). `secretBearing` marks features
    # that pull a secret onto a host, so an exposed host can refuse to grant them
    # (ADR-0015 threat model). Keys must match the feature vocabulary above.
    featureMeta = {
      gui.secretBearing = false;
      # secretFiles: stash-relative sops files this feature pulls onto a granting
      # host. The recipient set of each file is *derived* from which hosts grant
      # the feature (self.lib.featureRecipients) — the single source of truth.
      restic = {
        secretBearing = true;
        secretFiles = [ "profiles/restic.yaml" ];
      };
      workstation.secretBearing = false;
      virtualization.secretBearing = false;
      # signing handles a secret (so it is excluded from the future safe set and the
      # exposed-host ban applies — a greeter user never auto-gets it, no exposed host
      # holds it). But the secret rides the USER's home sops (like restic), decrypted
      # by the user's own key — so there is no host re-key and no host recipients
      # (no secretFiles). See users/inkpotmonkey/home/signing.nix (ADR-0018, slice 13).
      signing.secretBearing = true;
    };
    # Groups a user may NOT obtain by merely declaring them in identity.extraGroups
    # (untrusted input) — they require a feature grant. Enforced by the clamp in
    # realization.nix (ADR-0015 threat model: powers come from grants, not raw data).
    privilegedGroups = [
      "docker"
      "podman"
      "wheel"
      "libvirtd"
      "kvm"
      "disk"
      "qemu-libvirtd"
    ];
    # The privileged groups each feature grant confers.
    featureGroups = {
      workstation = [
        "docker"
        "podman"
        "wheel"
      ];
      # The desktop hardware groups, conferred by the gui grant via the realization's
      # clamp+grantedGroups path. All non-privileged, so gui stays in the safe set
      # (ADR-0018, slice 11). video is conferred via identity already.
      gui = [
        "input"
        "uinput"
        "plugdev"
        "dialout"
      ];
      # The privileged virtualization groups, split out of gui (slice 11) so they are
      # build-time-only, never on a greeter-grantable feature. kvm is intentionally
      # omitted: it is not conferred to any user today (behaviour-neutral).
      virtualization = [
        "disk"
        "qemu-libvirtd"
        "libvirtd"
      ];
    };
  };
}
