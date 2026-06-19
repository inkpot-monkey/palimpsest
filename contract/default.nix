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
      # clamp+grantedGroups path (so they ride the grant, not a raw user write — slice
      # 10). NOTE: disk/qemu-libvirtd/libvirtd are privileged and split into a
      # `virtualization` feature in slice 11; here they keep gui behaviour-neutral.
      gui = [
        "input"
        "uinput"
        "plugdev"
        "disk"
        "qemu-libvirtd"
        "dialout"
        "libvirtd"
      ];
    };
  };
}
