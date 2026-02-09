{
  pkgs,
  ...
}:

{
  boot.kernelModules = [
    "kvm-amd"
    "kvm-intel"
  ];

  virtualisation = {
    docker.enable = true;

    libvirtd.enable = true;
  };

  environment.systemPackages = with pkgs; [ docker-compose ];
}
