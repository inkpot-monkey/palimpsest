{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.virtualization;
in
{
  options.custom.profiles.virtualization = {
    enable = lib.mkEnableOption "virtualization configuration (Docker, libvirtd)";
  };

  config = lib.mkIf cfg.enable {
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
  };
}
