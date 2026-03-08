{
  flake.nixosProfiles = {
    # --- Core / System Profiles ---
    base = ./base.nix;
    nixConfig = ./nixConfig.nix;
    sops = ./sops.nix;
    impermanence = ./impermanence.nix;
    nebula = ./nebula.nix;
    tailscale = ./tailscale.nix;
    server = ./server.nix;
    wireless = ./wireless.nix;
    zsa = ./zsa.nix;

    # --- Desktop / GUI Profiles ---
    gui-base = ./gui-base.nix;
    fonts = ./fonts.nix;
    audio = ./audio.nix;
    bluetooth = ./bluetooth.nix;
    regreet = ./regreet.nix;
    gaming = ./gaming.nix;
    direnv = ./direnv.nix;
    virtualization = ./virtualization.nix;

    # --- Application / Service Profiles ---
    matrix = ./matrix.nix;
    mail = ./mail.nix;
    paperless = ./paperless.nix;
    proxy = ./proxy.nix;
    podman = ./podman.nix;
    affine = ./affine.nix;
    transmission = ./transmission.nix;
    litellm = ./litellm.nix;
    ai = ./ai.nix;
    backup = ./backup.nix;
    blocky = ./blocky.nix;
    monitoring = {
      client = ./monitoring/client.nix;
      server = ./monitoring/server.nix;
      smartctl = ./monitoring/smartctl.nix;
    };

    # --- Hardware Specific (Pi) ---
    pi = ./pi;
    hifiberry = ./pi/hifiberry.nix;
    hifi = ./pi/hifi.nix;
  };
}
