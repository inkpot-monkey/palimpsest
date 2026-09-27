{
  config,
  lib,
  pkgs,
  ...
}:

# Docker on its own, split out from `virtualization`.
#
# `virtualization` already enables Docker, but it is a VM-workstation bundle: libvirtd with
# swtpm, virt-manager, virt-viewer, the whole spice stack, virtio-win and win-spice. A host
# that wants a container runtime and no hypervisor should not pay that closure, and — more
# to the point — should not have to say the word "virtualization" to get one. The contract's
# operator grant makes exactly that distinction upstream: it confers `containers` and leaves
# `virtualization` deliberately absent (hosts/default.nix). This profile is the host-side
# half of the same split, so `custom.profiles.docker` matches the affordance that grants it.
#
# The group is NOT set here. `containers` confers docker/podman membership through the
# contract's grant→group registry, conditional on the runtime existing; enabling the runtime
# is the whole of the host's job, and an `extraGroups` line here would duplicate registry
# data the contract owns (see parts/checks/contract-seat).
#
# Coexists with `podman`: both may be enabled, but `virtualisation.oci-containers.backend`
# is single-valued, so a host running declarative containers should enable only the one it
# means to serve them with.

let
  cfg = config.custom.profiles.docker;
in
{
  options.custom.profiles.docker = {
    enable = lib.mkEnableOption "Docker container runtime configuration";
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/docker"
      ];
    };

    environment.systemPackages = with pkgs; [
      docker-compose
    ];
  };
}
