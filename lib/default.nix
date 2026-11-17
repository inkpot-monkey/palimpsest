{ inputs, self, ... }:
let
  overlays = import ../modules/shared/overlays { inherit inputs; };
  inherit (inputs.nixpkgs) lib;

  # The getSecret* helpers fall back to checked-in mock files when a path is absent
  # from the `secrets` input, so the flake evaluates standalone (public clone / fresh
  # checkout before secrets are wired). The fallback is deliberately LOUD — a silent
  # mock substitution during a real build would mask a missing/mis-pathed secret, so
  # each fallback warns. (Originally added for Garnix CI, now defunct; the standalone
  # eval-ability is kept for the public repo. See docs/adr/0012.)
  warnMock =
    what: fallback:
    lib.warn "secrets: '${what}' not present in the secrets input — falling back to a MOCK; real secrets are NOT used." fallback;

  helpers = lib // {
    inherit overlays;

    # Per-service log-format regexes for monitoring/client.nix's `levelFromMessage`, exposed
    # through `self.lib` so a profile at any depth reaches them the same way and so
    # parts/checks/log-levels can enumerate the whole catalogue. See the file's header for the
    # escaping trap that is the main reason they live in one place.
    logLevelPatterns = import ../modules/shared/log-level-patterns.nix;

    # ── READING THE SERVICE REGISTRY, ONCE ───────────────────────────────────────────
    # An entry in `settings.services.*` declares EITHER a single `port`, or -- when it is
    # a path-routed vhost (`paths`, property#8) -- an attrset of prefix → port. Four places
    # used to decide that difference for themselves: proxy.nix's vhost generator,
    # settings.nix's port-collision guard, monitoring/watcher.nix's probe builder, and the
    # uptime check's own fixtures. Nothing made them agree.
    #
    # The real hazard was never "a third shape costs a fourth edit". It is that a
    # MALFORMED entry behaved DIFFERENTLY in each consumer rather than failing: one
    # carrying both `port` and `paths` had its ports counted by the collision guard,
    # routed by prefix in Caddy, and probed twice; one carrying neither contributed
    # nothing, anywhere, silently. Either is a vhost serving the wrong thing with every
    # check green. `shapeViolations` is the one place that can refuse them, and
    # parts/checks/service-routes holds it to that.
    #
    # NOT named `services`: `lib.services` already exists upstream.
    serviceRoutes = rec {
      isPathRouted = svc: svc ? paths;

      # Which host actually LISTENS: the origin when the service runs off its edge (Home
      # Assistant on rk1a, the boards on rk1b), otherwise the edge it sits beside.
      listenerHost = svc: svc.origin or svc.edge;

      # Every real listener this entry opens. Both shapes answer, so a port collision
      # between a board and a service cannot hide from the guard that exists to catch it.
      portsOf = svc: if isPathRouted svc then lib.attrValues svc.paths else [ svc.port ];

      # Prefix → port, as an ordered list. A single-port entry has exactly one route at
      # the vhost root (`prefix = ""`), which is what lets a consumer treat both shapes
      # the same way instead of branching. Sorted by prefix so generated output is stable.
      routesOf =
        svc:
        if isPathRouted svc then
          map (prefix: {
            inherit prefix;
            port = svc.paths.${prefix};
          }) (lib.sort (a: b: a < b) (lib.attrNames svc.paths))
        else
          [
            {
              prefix = "";
              inherit (svc) port;
            }
          ];

      # The shape invariant, as named violations rather than a bare throw: the caller
      # decides whether to fail the build or report, and the message says which entry.
      shapeViolations =
        svcs:
        lib.filter (v: v != null) (
          lib.mapAttrsToList (
            name: svc:
            if (svc ? port) && (svc ? paths) then
              "${name}: declares both `port` and `paths`; an entry is one shape or the other"
            else if !(svc ? port) && !(svc ? paths) then
              "${name}: declares neither `port` nor `paths`, so it has no listener"
            else
              null
          ) svcs
        );
    };

    mkPkgs =
      system:
      import inputs.nixpkgs {
        inherit system;
        overlays = [ overlays.default ];
        config = {
          allowUnfree = true;
        };
      };

    getSecretPath =
      subpath:
      let
        path = "${inputs.secrets}/${subpath}";
        isNix = inputs.nixpkgs.lib.hasSuffix ".nix" subpath;
        fallback = if isNix then ../parts/mock-identities.nix else ../parts/mock-secrets.yaml;
      in
      if builtins.pathExists path then path else warnMock subpath fallback;

    getSecretFile =
      name:
      let
        path = "${inputs.secrets}/profiles/${name}.yaml";
      in
      if builtins.pathExists path then
        path
      else
        warnMock "profiles/${name}.yaml" ../parts/mock-secrets.yaml;

    getHostSecretFile =
      host:
      let
        path = "${inputs.secrets}/hosts/${host}/secrets.yaml";
      in
      if builtins.pathExists path then
        path
      else
        warnMock "hosts/${host}/secrets.yaml" ../parts/mock-secrets.yaml;

    getHostNamedSecretFile =
      host: name:
      let
        path = "${inputs.secrets}/hosts/${host}/${name}.yaml";
      in
      if builtins.pathExists path then
        path
      else
        warnMock "hosts/${host}/${name}.yaml" ../parts/mock-secrets.yaml;

    getUserSecretFile =
      user:
      let
        path = "${inputs.secrets}/users/${user}.yaml";
      in
      if builtins.pathExists path then path else warnMock "users/${user}.yaml" ../parts/mock-secrets.yaml;

    # The host's implementation of the contract `platform` interface (contract ADR-0004 Q7): the
    # one place the system names its secrets backend. Set as `config.custom.platform` by
    # both the system and home wiring (users/identity.nix, modules/homeManager/options.nix)
    # so the binding lives in exactly one place instead of being duplicated per eval-side.
    platformBinding = {
      secretFile = helpers.getSecretFile;
      secretPath = helpers.getSecretPath;
    };

    # Email Config Helpers
    mkMbsyncAccount =
      {
        name,
        host,
        user,
        passCmd,
        port ? null,
        tlsType ? "IMAPS",
        authMechs ? "LOGIN",
        extraConfig ? "",
      }:
      ''
        IMAPAccount ${name}
        Host ${host}
        User ${user}
        PassCmd "${passCmd}"
        AuthMechs ${authMechs}
        TLSType ${tlsType}
        ${lib.optionalString (port != null) "Port ${builtins.toString port}"}
        ${extraConfig}
      '';

    mkMbsyncChannel =
      {
        name,
        account,
        far,
        near,
        patterns ? "*",
        create ? "Both",
        expunge ? "Both",
        remove ? "None",
      }:
      ''
        Channel ${name}
        Far :${account}-remote:${far}
        Near :${account}-local:${near}
        Patterns ${patterns}
        Create ${create}
        Expunge ${expunge}
        Remove ${remove}
      '';

    mkSystem =
      {
        modules,
        specialArgs ? { },
      }:
      inputs.nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit (self) settings;
          inherit
            inputs
            self
            ;
          homeManagerInput = inputs.home-manager;
        }
        // specialArgs;
        modules = modules ++ [
          {
            nixpkgs.overlays = [ overlays.default ];
            nixpkgs.config.allowUnfree = true;
          }
        ];
      };

    mkPiSystem =
      {
        modules,
        specialArgs ? { },
      }:
      inputs.nixos-raspberrypi.lib.nixosSystem {
        specialArgs = {
          inherit (self) settings;
          inherit
            inputs
            self
            ;
          inherit (inputs) nixos-raspberrypi;
          homeManagerInput = inputs.home-manager;
        }
        // specialArgs;
        modules = modules ++ [
          {
            nixpkgs.overlays = [ overlays.default ];
            nixpkgs.config.allowUnfree = true;
          }
        ];
      };
  };
in
{
  flake.overlays = helpers.overlays.modifications;
  flake.lib = helpers;
}
