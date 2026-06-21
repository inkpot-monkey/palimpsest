{
  # The user's only shape is a non-granting **manifest** (ADR-0018, slice 16): identity
  # + home + the user's own feature configuration, with NO `granted.*`. Every host that
  # binds this user owns its grants as data (hosts/default.nix) — the user can never
  # self-grant. The self-granting `cli`/`gui` variants are gone, so self-granting is not
  # even expressible. The home adapts to host affordances purely via
  # `hostFacts.granted.gui` (cli base + gui layer), never a per-host variant.
  manifest =
    { ... }:
    {
      imports = [ ./bundle.nix ];
    };
}
