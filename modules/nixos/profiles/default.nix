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
    sudo = ./sudo.nix;
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
    openclaw = ./openclaw.nix;
    aionui = ./aionui.nix;
    homeassistant = ./homeassistant.nix;
    backup = ./backup.nix;
    blocky = ./blocky.nix;
    # Flat keys so each matches its enable option 1:1 (custom.profiles.<key>), the same
    # invariant every other profile follows. Nothing imports these à la carte; the bundle
    # picks them up via lib.collect.
    monitoring-client = ./monitoring/client.nix;
    monitoring-server = ./monitoring/server.nix;
    monitoring-smartctl = ./monitoring/smartctl.nix;
    monitoring-exporters = ./monitoring/exporters.nix;
    monitoring-dmarc = ./monitoring/dmarc.nix;
    media = ./media;

    # --- Hardware Specific (Pi) ---
    pi = ./pi;
    hifiberry = ./pi/hifiberry.nix;
    hifi = ./pi/hifi.nix;

    # --- Build infrastructure ---
    # Offload aarch64 builds to the rk1 nodes. Gated OFF until they have NVMe storage.
    piBuilder = ./pi-builder.nix;
  };
}
