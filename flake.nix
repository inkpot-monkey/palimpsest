{
  description = "I am config and my code is a string that will be run.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.11";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager-25_11 = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixos-raspberrypi/nixpkgs";
    };

    # Pinned to 40861a6 (Mar 2026): this rev's DEFAULT is the *stable*-branch RPi vendor
    # kernel linux_rpi-bcm2711-6.12.47-stable (+ matched firmware 1.20250915), both cached
    # on nixos-raspberrypi.cachix.org (no local kernel compile). Stay on a *stable*-branch
    # kernel: the *unstable/next* branch (e.g. 6.12.87 on rev 06c6e351, or 6.18.x on the
    # develop branch) hangs porcupineFish in the initrd before systemd (empty /var, root
    # never grows). Only bump to another rev whose default is a newer *stable* kernel, and
    # re-validate a porcupineFish boot — see hosts/porcupineFish/README.md.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/40861a63b4162f9332d03e125d76b9b8e2bbe79c";

    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:nixos/nixos-hardware";

    nixos-turing-rk1 = {
      url = "github:GiyoMoon/nixos-turing-rk1";
      # Without follows, the module injects its own pinned nixpkgs (25.11) as `pkgs`, causing a
      # mismatch: unstable's device-tree.nix and top-level.nix read kernel.buildDTBs / kernel.target
      # from passthru, but the stable kernel doesn't expose those.  Both attributes exist in
      # unstable, so aligning the nixpkgs fixes the mismatch and keeps ubootTuringRK1 from unstable.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    emacs-overlay.url = "github:nix-community/emacs-overlay";

    vpsFree.url = "github:vpsfreecz/vpsadminos";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llm-agents = {
      url = "github:numtide/llm-agents.nix";
    };

    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    openclaw-nix = {
      url = "github:openclaw/nix-openclaw";
    };

    # Community repackaging of the Claude Desktop app for Linux (no official
    # Linux build exists). Extracts the macOS app's resources, stubs the
    # macOS-native modules (@ant/claude-swift, @ant/claude-native) with a Linux
    # orchestration layer, and runs the Claude Code binary directly on the host
    # under bubblewrap — so Cowork *skills actually execute* on Linux. We
    # switched off Reginleif88/claude-cowork-nix because that fork ships only the
    # Electron shell: it never downloads the Cowork VM rootfs nor stubs the VM
    # backend, so every launch logged `rootfs.img missing` and any skill that
    # needed code execution failed (no sandbox to run in). Keep its own nixpkgs
    # pin (nixos-25.11, what the author tests). Trade-off: no real VM — skills
    # run on the host under bubblewrap, weaker isolation than the macOS VM.
    claude-cowork-linux = {
      url = "github:johnzfitch/claude-cowork-linux";
    };

    # The email bridge lives in its own repo (ADR-0016), consumed via its
    # nixosModule. Deliberately NOT `inputs.nixpkgs.follows = "nixpkgs"`: the
    # bridge's CI builds the crate against its OWN pinned nixpkgs and pushes the
    # closure to the palebluebytes cachix (trusted in nixConfig.nix). Following
    # the fleet nixpkgs would change the store hash and force a from-source Rust
    # rebuild on every bump. We consume `inputs.jmap-bridge.packages.<system>`
    # directly (see matrix/jmap-bridge.nix) so kelpy substitutes the prebuilt
    # binary instead of compiling matrix-sdk/sqlx from source.
    #
    # Pinned to a RELEASE TAG, not `main`. A tag is by construction a revision
    # release-plz cut and CI already built and pushed, which removes the
    # "re-locked onto a tip CI never built" trap (see AGENTS.md) structurally
    # rather than by remembering to check. The cost is that the tag is immutable,
    # so `nix flake update jmap-bridge` is a NO-OP: bumping the bridge means
    # editing the tag below by hand. `gh release list --repo
    # palebluebytes/jmap-matrix-bridge` shows what is available.
    jmap-bridge.url = "github:palebluebytes/jmap-matrix-bridge/v0.5.6";

    secrets = {
      url = "git+ssh://git@github.com/inkpot-monkey/stash.git";
      flake = false;
    };

    # The host↔user contract (its ADR-0004): the shared schema, host-invariant realization,
    # derivation logic, and conformance kit. Now its own public repo, consumed as a
    # `github:` input — the "URL change, not a re-wire" of contract ADR-0001. nixpkgs follows the
    # fleet pin so there is one nixpkgs eval and no lib skew. Edit behaviour THERE, then
    # `nix flake update contract` here (the two-repo workflow of secrets/jmap-bridge).
    contract = {
      url = "github:palebluebytes/host-user-contract";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The operator's fleet users as their OWN external MULTI-USER home-manager flake (repo-split
    # capstone, issue #1) — `inkpotmonkey`, `eyeofalligator`, … each a confined ADR-0007 home,
    # consumed via the contract's pre-built binding (bindContractPackage, ADR-0016). Currently only
    # bound by the `prebuilt_bind_external` integration check — NOT yet by any production host (that
    # cutover waits for the full homes to migrate). `contract` follows the fleet's so there is ONE
    # contract/lib eval and the repo's own relative `path:` contract input is bypassed.
    # nixpkgs deliberately does NOT follow the fleet's: the pre-built home is built with the
    # users repo's OWN nixpkgs (the toolchain its CI tests), keeping it isolated from the
    # fleet's pin (the point of the pre-built model). Following made the fleet REBUILD the home
    # against the fleet nixpkgs and drift — e.g. the gui/ai closure needs a package name only
    # the users' newer pin exposes. Cost: a second nixpkgs closure in the fleet.
    # DEV: local `git+file:`; flips to `github:palebluebytes/users` at T7 — a URL change.
    # `git+file:` (not `path:`) enumerates git-TRACKED files, so it never copies `.git/`
    # into the store — sidestepping the `fsmonitor--daemon.ipc` socket that broke the
    # `path:` copier. Only committed content is seen.
    users = {
      url = "git+file:///home/inkpotmonkey/code/users";
      inputs.contract.follows = "contract";
    };

    # The Supernote toolkit (self-hosted Private Cloud Sync server + client) — the FORK
    # `inkpot-monkey/supernote`, pinned to an explicit revision. palimpsest#112 moved this to
    # upstream on the reasoning that upstream had implemented the device planner/realtime surface
    # the fork existed to add; that held for the planner and NOT for the realtime channel, which
    # upstream cannot serve to this device at any option setting (palimpsest#145). See the note on
    # the input below for what the fork carries and how it goes away.
    #
    # A bare `?rev=` rather than a branch ON PURPOSE: this is the device sync endpoint, and an
    # unattended `nix flake update` that drags in an alembic migration would silently migrate
    # the live store. Moving it must be a deliberate, reviewed edit of the rev below (take a
    # `sqlite3 .backup` of /var/lib/supernote/system/supernote.db first — ADR-0031).
    #
    # `flake = false`: a plain Python repo, not a flake — packaged here as `pkgs.supernote`
    # (pkgs/supernote) with nixpkgs `buildPythonApplication`, so rk1b (aarch64) substitutes the
    # heavy deps from cache.nixos.org rather than compiling.
    #
    # Pinned to the FORK, not upstream (palimpsest#145, ADR-0031 revision 2026-08-18). The rev is
    # upstream 0.21.0 plus the device's Engine.IO v3 / Socket.IO v2 realtime channel, which upstream
    # cannot serve at any option setting. Fork `main` is byte-identical to upstream `main` and stays
    # so; this is a rev pin, not a branch, and it returns to `github:allenporter/supernote` the day
    # upstream merges the channel.
    #
    # Moved 2026-08-18 from 79d1003 to the tip of `fix/engineio-v3-device-support`, ten commits of
    # channel refinement. FIVE of them are behavioural: `e96aba2` matches the channel endpoint by
    # `rstrip("/")` rather than by prefix and `7100eb9` narrows that again to the two exact
    # spellings; `6996ab5` honours socketio options declared on a base class (startup path only —
    # if it were wrong the server would not start); `5bd12c4` drops the client-namespace CONNECT
    # echo (behaviour-preserving for anything observed, since the seed set already held "/"); and
    # `177f370` enforces the ping timeout the handshake advertises. The rest are tests and docs.
    #
    # `177f370` is the one to watch: it introduces a failure mode that did not exist at 79d1003 —
    # the server now hangs up after pingInterval + pingTimeout (85s) of silence where before it
    # held forever. That bound is where a real Engine.IO v3 server declares a client dead, not a
    # chosen number, and the device capture shows pings every 25s, so observed traffic never
    # approaches it; the device also reopens on its own ladder, making the worst case one extra
    # reconnect.
    #
    # NOTE 79d1003 is the rev #145's hardware pass was run against, so a device sync after this
    # bump re-establishes that result rather than inheriting it. Rolling this pin back is safe on
    # its own terms: the ten commits touch only server/{app,realtime,socket}.py and their tests —
    # no migrations, no schema — so unlike the 0.21.0 move it carries no database implication.
    supernote = {
      url = "github:inkpot-monkey/supernote?rev=33175b3202647a11c4b748f41fd5d870b8e7ecb3";
      flake = false;
    };

  };

  outputs =
    inputs@{
      self,
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks.flakeModule
        inputs.treefmt-nix.flakeModule
        ./parts/settings.nix
        ./parts/shells.nix
        ./parts/treefmt.nix
        ./parts/git-hooks.nix
        ./parts/templates.nix
        ./parts/apps
        ./parts/checks
        ./lib
        ./hosts
        ./modules/nixos/services
        ./modules/nixos/profiles
        ./modules/homeManager
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          system,
          ...
        }:
        {
          _module.args.pkgs = self.lib.mkPkgs system;
          packages = import ./pkgs {
            inherit pkgs inputs;
          };
        };
    };
}
