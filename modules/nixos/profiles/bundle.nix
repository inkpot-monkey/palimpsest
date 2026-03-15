{ ... }:

{
  imports = [
    ./base.nix
    ./nixConfig.nix
    ./sops.nix
    ./impermanence.nix
    ./nebula.nix
    ./tailscale.nix
    ./server.nix
    ./wireless.nix
    ./zsa.nix
    ./gui-base.nix
    ./fonts.nix
    ./audio.nix
    ./bluetooth.nix
    ./regreet.nix
    ./gaming.nix
    ./direnv.nix
    ./virtualization.nix
    ./matrix.nix
    ./mail.nix
    ./paperless.nix
    ./proxy.nix
    ./podman.nix
    ./affine.nix
    ./transmission.nix
    ./litellm.nix
    ./backup.nix
    ./blocky.nix
    ./monitoring/client.nix
    ./monitoring/server.nix
    ./monitoring/smartctl.nix
    ./monitoring/exporters.nix
  ];
}
