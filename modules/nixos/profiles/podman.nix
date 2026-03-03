{ pkgs, config, ... }:

{
  virtualisation = {
    oci-containers.backend = "podman";
    podman = {
      enable = true;
      extraPackages = [ pkgs.runc ];
    };
  };

  environment.persistence."/persistent" = {
    directories = [
      "/var/lib/containers"
    ];
  };

  environment.systemPackages = with pkgs; [
    podman-tui
    podman-compose
  ];
}
