rec {
  # The non-granting manifest (ADR-0018, slice 10): identity + home + the user's own
  # config, with NO `granted.*`. A host that imports this owns every grant as data
  # (see hosts/sawtoothShark/configuration.nix) — the user can never self-grant. The
  # profile is inert (grants gate now), so it is "cli" regardless of what is granted.
  manifest =
    { ... }:
    {
      imports = [ ./bundle.nix ];
      custom.users.inkpotmonkey.identity.profile = "cli";
    };

  cli =
    { ... }:
    {
      imports = [ ./bundle.nix ];
      custom.users.inkpotmonkey.identity.profile = "cli";
      # Transitional: every host currently gives inkpotmonkey docker/podman/wheel.
      # The workstation grant reproduces that; an exposed host (kelpy) should drop it.
      custom.users.inkpotmonkey.granted.workstation.enable = true;
    };
  gui =
    { ... }:
    {
      imports = [ ./bundle.nix ];
      custom.users.inkpotmonkey.identity.profile = "gui";
      # Choosing the gui variant is the host's grant of the gui feature (ADR-0015).
      custom.users.inkpotmonkey.granted.gui.enable = true;
      custom.users.inkpotmonkey.granted.workstation.enable = true;
    };
}
