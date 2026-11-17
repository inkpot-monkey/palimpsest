{
  config,
  lib,
  pkgs,
  settings,
  ...
}:

let
  cfg = config.custom.profiles.property-board;

  # This profile's own registry entry — the SHARED boards vhost kelpy serves
  # (property#8), of which this board is one path. Read from the registry rather
  # than restated, so the three facts that have to agree cannot drift: Caddy
  # proxies `boards.<domain><basePath>*` to `${svc.origin}.${tailnet}:${port}`,
  # that is exactly the address this process listens on, and `basePath` is
  # exactly the prefix it must route on and emit its links under.
  svc = settings.services.private.boards;

  # The prefix this board is served at, and the port behind it. Taken as the
  # single `paths` entry whose port this profile owns rather than by writing
  # "/property" twice — one of the two spellings would eventually be the stale
  # one, and the symptom would be a vhost that 502s with a healthy unit.
  basePath = "/property";
  port = svc.paths.${basePath};

  # Bare interpreter, deliberately: the board imports nothing outside the
  # standard library, which is what lets it run on a host with almost no
  # Python packages — the same constraint that shaped the job beside it.
  # Carrying ${pkgs.python3} from the flake rather than a pinned store path
  # means the interpreter is renewed by every rebuild.
  start = pkgs.writeShellScript "property-board-start" ''
    set -euo pipefail

    # ── BIND THE TAILSCALE ADDRESS, NOT 0.0.0.0 ──────────────────────────────
    # litellm, immich and opencode next door bind the wildcard and lean on the
    # firewall rule below. This one must not: it carries no login at all (the
    # tailnet guard in Caddy is the whole access control, by decision), so a
    # wildcard bind would also answer on rk1b's LAN interface with the firewall
    # rule as the single thing in the way. Binding one address makes the reach
    # a property of the socket rather than of a rule that could be narrowed.
    #
    # The address is not known at build time and tailscaled may not have
    # brought the interface up when this unit starts, so poll for it. Bounded,
    # because a unit that waits forever is indistinguishable from a hung one.
    addr=""
    for _ in $(seq 1 60); do
      addr=$(${pkgs.iproute2}/bin/ip -4 -o addr show dev tailscale0 2>/dev/null \
               | ${pkgs.gawk}/bin/awk '{print $4}' | ${pkgs.coreutils}/bin/cut -d/ -f1)
      [ -n "$addr" ] && break
      ${pkgs.coreutils}/bin/sleep 2
    done
    if [ -z "$addr" ]; then
      echo "tailscale0 has no IPv4 after 120s; refusing to fall back to 0.0.0.0" >&2
      exit 1
    fi

    # ── AND IT IS TOLD WHERE IT IS SERVED ───────────────────────────────────
    # Caddy FORWARDS the `/property` prefix rather than stripping it, so this
    # process routes on it and the page emits its links under it. One URL space
    # end to end: what the browser asks for is what arrives here. Without this
    # the board would answer at `/` and the vhost would 404 every request.
    exec ${pkgs.python3}/bin/python3 ${./property-board.py} \
      --db ${cfg.databasePath} --host "$addr" --port ${toString port} \
      --base-path ${basePath}
  '';
in
{
  options.custom.profiles.property-board = {
    enable = lib.mkEnableOption "the property board — map, favourites and price history over the property-watch corpus (property#5)";

    databasePath = lib.mkOption {
      type = lib.types.path;
      default = "${config.custom.profiles.property-watch.stateDir}/data/property-watch.db";
      description = "The shared database. The job writes it; this reads it and writes `favourites`.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The board is nothing without the corpus, and the corpus profile is what
    # declares the group, the setgid directories and the GID pin this unit
    # depends on. An assertion rather than an implicit `enable = true`: turning
    # on a daily crawler as a side effect of asking for a web page would be a
    # surprise worth refusing.
    assertions = [
      {
        assertion = config.custom.profiles.property-watch.enable;
        message = "custom.profiles.property-board needs property-watch on the same host: it reads that profile's database and joins its group.";
      }
    ];

    # ── THE READER'S IDENTITY ────────────────────────────────────────────────
    # A static system user rather than DynamicUser. The whole point of this
    # process is a file shared with another service through a pinned GID, and a
    # transient uid that changes under it is the shape of problem this fleet
    # already has a memory of (see the GID-pin comment in property-watch.nix).
    users.groups.property-board = { };
    users.users.property-board = {
      isSystemUser = true;
      group = "property-board";
      description = "The property board's web process (property#5)";
      # ⚠ ADDING A USER TO A GROUP DOES NOTHING UNTIL THE UNIT RESTARTS.
      # `nixos-rebuild switch` will not restart a unit whose own definition is
      # unchanged, so a later change to this list needs `systemctl restart
      # property-board` by hand or it will keep running with the old
      # supplementary groups and fail its writes with a permissions error that
      # the configuration says cannot happen.
      extraGroups = [ "property-watch" ];
    };

    systemd.services.property-board = {
      description = "The property board (property#5)";
      wantedBy = [ "multi-user.target" ];
      # tailscaled, because the bind address comes from its interface; the
      # tmpfiles the corpus profile declares, because the database's DIRECTORY
      # must exist and be setgid before sqlite creates anything in it.
      after = [
        "network-online.target"
        "tailscaled.service"
        "systemd-tmpfiles-setup.service"
      ];
      wants = [ "network-online.target" ];

      # A change to the page or the queries is a change to what this serves, so
      # the unit must restart for it. Without this the deploy would succeed and
      # the old code would keep answering.
      restartTriggers = [ start ];

      serviceConfig = {
        User = "property-board";
        Group = "property-board";
        SupplementaryGroups = [ "property-watch" ];
        ExecStart = start;
        Restart = "on-failure";
        RestartSec = 5;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK" # `ip addr` reads the interface through a netlink socket
        ];
        RestrictNamespaces = true;
        LockPersonality = true;

        # ── AND THE SANDBOX HAS TO AGREE ─────────────────────────────────────
        # THE SAME TRAP THE JOB HIT, AND IT WILL LOOK LIKE A PERMISSIONS BUG.
        # ProtectSystem=strict makes the whole hierarchy read-only to this unit
        # however the file modes read, and the failure is not "permission
        # denied" on the favourites row — it is `PRAGMA journal_mode=WAL`
        # failing with "unable to open database file" at startup. It does NOT
        # reproduce under `sudo -u property-board`, because that has no sandbox.
        #
        # The DIRECTORY and not the file: sqlite creates `-wal` and `-shm`
        # beside the database, so write on the file alone is not enough.
        #
        # Note what is NOT granted: the parent, which holds the buying brief.
        # That stays read-only to this unit at the systemd layer as well as by
        # ownership, exactly as it does for the job.
        ReadWritePaths = [ "${config.custom.profiles.property-watch.stateDir}/data" ];
      };
    };

    # Tailscale peers only — NOT `networking.firewall.allowedTCPPorts`, which
    # would also publish the board on rk1b's LAN interface. Belt-and-braces
    # given the bind above resolves to the tailscale address anyway: the rule is
    # what keeps the port closed should that bind ever be loosened, and it
    # states the intent where the port is.
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];
  };
}
