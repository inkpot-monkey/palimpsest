{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.profiles.podman;
in
{
  options.custom.profiles.podman = {
    enable = lib.mkEnableOption "Podman container runtime configuration";
  };

  config = lib.mkIf cfg.enable {
    virtualisation = {
      oci-containers.backend = "podman";
      podman = {
        enable = true;
        extraPackages = [ pkgs.runc ];
      };
    };

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/containers"
      ];
    };

    environment.systemPackages = with pkgs; [
      podman-tui
      podman-compose
    ];
  };
}
