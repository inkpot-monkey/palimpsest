{
  flake.nixosProfiles = {
    # --- Bundle Profile ---
    bundle = ./bundle.nix;
    pi-bundle = ./pi/bundle.nix;

    # --- Core / System Profiles ---
    base = ./base.nix;
    nixConfig = ./nixConfig.nix;
    sops = ./sops.nix;
    impermanence = ./impermanence.nix;
    nebula = ./nebula.nix;
    tailscale = ./tailscale.nix;
    ssh = ./ssh.nix;
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
    matrix = ./matrix;
    mail = ./mail;
    paperless = ./paperless.nix;
    proxy = ./proxy.nix;
    podman = ./podman.nix;
    affine = ./affine;
    litellm = ./litellm.nix;
    local-llm = ./local-llm.nix;
    openclaw = ./openclaw.nix;
    backup = ./backup.nix;
    blocky = ./blocky.nix;
    monitoring = {
      client = ./monitoring/client.nix;
      server = ./monitoring/server.nix;
      smartctl = ./monitoring/smartctl.nix;
      exporters = ./monitoring/exporters.nix;
      dmarc = ./monitoring/dmarc.nix;
    };
    n8n = ./n8n.nix;
    media = ./media;
    owncloud = ./owncloud.nix;

    # --- Hardware Specific (Pi) ---
    pi = ./pi;
    hifiberry = ./pi/hifiberry.nix;
    hifi = ./pi/hifi.nix;
  };
}
