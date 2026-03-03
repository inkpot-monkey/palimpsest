{ pkgs, ... }:

{
  boot.kernelModules = [
    "kvm-amd"
    "kvm-intel"
  ];

  # Manage the virtualisation services
  virtualisation = {
    docker.enable = true;
    libvirtd = {
      enable = true;
      qemu = {
        swtpm.enable = true;
      };
    };
    spiceUSBRedirection.enable = true;
  };
  services.spice-vdagentd.enable = true;

  # Enable dconf (System Management Tool)
  programs.dconf.enable = true;

  # Add user to libvirtd group (Note: This assumes 'inkpotmonkey' user exists or is handled elsewhere,
  # but profiles should be generic. Ideally user config handles groups, or we append to a list.
  # For now, we'll keep the group creation but maybe not the user assignment if it's too specific.
  # Actually, profiles often configure specific users if known, but better to let user module handle it.
  # However, I'll include the package installations.)

  # Install necessary packages
  environment.systemPackages = with pkgs; [
    docker-compose
    virt-manager
    virt-viewer
    spice
    spice-gtk
    spice-protocol
    virtio-win
    win-spice
    adwaita-icon-theme
  ];
}
