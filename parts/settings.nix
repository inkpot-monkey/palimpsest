{ inputs, self, ... }:
let
  # Load node metadata from secrets/nodes.nix. getSecretPath returns the real file when
  # the secrets input provides it, else a mock (and warns) so the flake still evaluates
  # standalone — see lib/default.nix and docs/adr/0012. The mock has no node keys, so
  # every lookup below cleanly falls through to its placeholder.
  secretsNodes = import (self.lib.getSecretPath "nodes.nix");

  # Look up node metadata (tailscale/public IPs), falling back to a placeholder when an
  # entry is absent. The fallback is LOUD (mirrors lib's warnMock): a placeholder IP
  # silently reaching DNS/blocky during a real build would be a hard-to-spot mistake.
  getMeta =
    nodeName: path: default:
    let
      attrPath = [ nodeName ] ++ path;
      found = lib.attrByPath attrPath null secretsNodes;
    in
    if found != null then
      found
    else
      lib.warn "settings: node metadata '${lib.concatStringsSep "." attrPath}' missing from secrets/nodes.nix — using placeholder ${builtins.toJSON default}." default;

  inherit (inputs.nixpkgs) lib;
  primaryDomain = "palebluebytes.space";

  # The Anthropic org's Default workspace, required as a header by the user-scoped API key
  # (see the model catalogue below). Bound once so three entries cannot disagree.
  anthropicWorkspace = "wrkspc_01Pysv1dkPYrFz1Snpth6oBz";

  # The service registry. Each entry: `edge` (host where DNS points + Caddy runs),
  # `port`, optional `origin` (host actually running it when off-edge), optional
  # `proxy = false` (bypass Caddy). An entry may instead carry `paths` — an attrset of
  # URL prefix → port — in place of `port`, which makes the name a path-routed vhost
  # over several backends with a generated index at `/` (see `boards`, property#8).
  # Optional `monitor` controls the ADR-0019 uptime watcher (monitor-by-default):
  # `monitor.enable` (default true) and, when you set it false, a required
  # `monitor.reason`. Opting out here exempts a SERVED service
  # from probing/alerting; it does not stop Caddy fronting it (to fully retire a
  # service, remove its entry). The slice-04 flake-check guard enforces both the
  # reason-when-disabled rule and that every monitored service has a buildable probe.
  #
  # ⚠ ADDING AN ENTRY IS A FLEET-WIDE DEPLOY, not an edge/origin one. Several entries
  # below say "DEPLOY BOTH HOSTS", meaning the edge (for the Caddy vhost) and the origin
  # (for the service) — but that is not the whole list. A private entry's hostname is also
  # baked into blocky's generated hosts file (profiles/blocky.nix) on EVERY host in
  # `dns.nameserverHosts` below, at build time. Deploy only some of them and the name
  # resolves INTERMITTENTLY, because MagicDNS spreads queries across the fleet resolvers:
  # measured 2026-09-29, `forge` answered from kelpy's blocky and NXDOMAIN'd from rk1b's
  # until rk1b was deployed too — so from a workstation it simply did not resolve.
  services = {
    public = {
      matrix = {
        edge = "kelpy";
        port = 6167;
        proxy = false;
      };
      mail = {
        edge = "kelpy";
        port = 8082;
        proxy = false;
      };
      # matrix-hookshot's public webhook/OAuth listener. Caddy auto-fronts it
      # (proxy omitted → vhost created, DNS grey-clouded) so GitHub and generic
      # webhooks can POST in. The appservice port (loopback) is internal, kept in
      # the hookshot module. See modules/nixos/profiles/matrix/hookshot.nix.
      hookshot = {
        edge = "kelpy";
        port = 9000;
      };
    };
    private = {
      # The Hermes agent runtime's admin panel (modules/nixos/profiles/hermes.nix). RUNS on
      # rk1b, fronted by kelpy's Caddy at agent.<domain> behind the internal_only guard —
      # the same edge/origin split as music, ma and library. DEPLOY BOTH HOSTS, plus every
      # `dns.nameserverHosts` resolver (see the warning above the registry).
      #
      # ⚠ THE TAILNET GUARD IS NOT THE ONLY THING IN FRONT OF THIS, AND MUST NOT BE. This
      # panel carries a PTY on rk1b as the `hermes` user, and the tailnet is not
      # single-person (ADR-0027 puts friends on it for music and photos). So the backend
      # runs its own username/password gate on top; `--insecure` is not an option even if
      # one wanted it, because upstream IGNORES that flag since their June 2026 incident
      # (web_server_boundary.should_require_auth). See the profile for the credentials.
      agent = {
        edge = "kelpy";
        port = 9119;
        origin = "rk1b";
      };
      # opencode — server-side agent sessions (GLOSSARY.md), the first build on the
      # palimpsest#118 map. RUNS on rk1b, fronted by kelpy's Caddy at chat.<domain> behind
      # the internal_only guard. DEPLOY BOTH HOSTS plus both resolvers, as above.
      #
      # ⚠ SAME WARNING AS `agent`, MORE SO. A session here is arbitrary code execution on
      # rk1b with write access to the trees it is pointed at, so the tailnet guard is not
      # the control — opencode's own Basic-auth server password is (profiles/opencode.nix).
      # Note the gate covers `/api/*` ONLY; every other path serves the SPA shell 200
      # unauthenticated, so probe /api/session if you want to prove the gate is on.
      chat = {
        edge = "kelpy";
        port = 4096;
        origin = "rk1b";
      };
      # ── THE SHARED BOARDS VHOST (forge inkpotmonkey/property#8) ─────────────────────
      # A *board* is a page an agent job produces so a human can look at what it found.
      # They are all the same kind of thing and there will be more of them, so they share
      # ONE name, path-routed, instead of spending a name each — `boards.<domain>/property`
      # rather than `property.<domain>`. Adding the next one is a line here plus a port:
      # no DNS record, no DNS push, no blocky entry, no new nameserver deploy.
      #
      # `paths` IS THE ONLY ENTRY SHAPE IN THIS REGISTRY WITH NO `port`, and that is the
      # point — one name, several backends. Each prefix is reverse-proxied to its own
      # process on `origin`: a board that crashes must not take the others down, and they
      # are written by different jobs at different times. proxy.nix emits one `handle
      # <prefix>*` per entry and serves a generated index at `/`; the collision guard below
      # counts every one of these ports, because they are real listeners.
      #
      # ⚠ A BOARD MUST TOLERATE BEING SERVED UNDER A PREFIX, and Caddy does NOT strip it:
      # the prefix is forwarded and the app is told what it is (`--base-path`), so there is
      # one URL space end to end — what the browser asks for is what the process sees.
      # Stripping with `handle_path` would still leave the app needing to know the prefix in
      # order to emit correct links, so it buys nothing and adds a second coordinate system.
      # This is a convention for OUR boards, not a rule for every service: a third-party app
      # that cannot do it keeps its own name.
      #
      # ⚠ STILL DEPLOY BOTH HOSTS **the first time** (the edge for the vhost, rk1b for the
      # board) plus both resolvers for the name itself. It is only the SECOND and later
      # boards that cost one deploy of the origin.
      #
      # ⚠ THE TAILNET GUARD IS THE ONLY THING IN FRONT OF THESE, AND THAT IS A DECISION,
      # NOT AN OVERSIGHT — unlike `agent` and `chat` above, which carry a PTY and arbitrary
      # code execution and so must have a second gate. A board is a read-only view plus, at
      # most, a star to click. The tailnet is not single-person (ADR-0027), so what a
      # housemate or a friend could see on the property board is which flats are being
      # looked at and the budget they fall under. Judged acceptable against the cost of a
      # credential to rotate and a login to get past on a phone. If that judgement ever
      # changes, hermes.nix:73-111 is the sops-template basic-auth pattern to copy — and it
      # would then apply to every board at once, which is an argument for this shape rather
      # than against it.
      #
      # ⚠ EACH BOARD GETS ITS OWN UPTIME PROBE (watcher.nix), and it must. A probe on
      # `boards` alone proves Caddy, the cert and the index page Caddy itself serves — it
      # would be green with every board dead, which is precisely the silent failure
      # property#3 exists to prevent.
      boards = {
        edge = "kelpy";
        origin = "rk1b";
        paths = {
          # The property board (property#5): every live listing on a map, its price
          # history, and the latest verdict the model left on it with the price it was
          # judged at (property#7 -- there is no score; a model's mark out of ten is not
          # comparable across days, so it is never stored). RUNS on
          # rk1b beside the database it reads (profiles/property-board.nix).
          #
          # 9120, one past hermes's 9119, because the two are the same shape of thing on
          # the same host and reading them adjacent in `ss -lntp` is worth something.
          # Checked free against rk1b's live listeners, not only against this registry —
          # the collision guard below compares entries to each other and cannot see a
          # non-registry listener.
          "/property" = 9120;
        };
      };
      # Jellyfin. RUNS on rk1b with the rest of custom.profiles.media (the stack moves
      # as one: qBittorrent and slskd share gluetun's netns and jellyfin is gated on the
      # same profile flag), fronted by kelpy's Caddy — the same edge/origin split as
      # Navidrome, Stump and photos. The port itself is open on tailscale0 only.
      #
      # TAILNET-ONLY SINCE 2026-11-13, the second half of palimpsest#193 (the move to
      # rk1b was the first and landed earlier). It was `public` until then, which meant
      # its vhost was the one thing on this edge deliberately exempt from the
      # internal_only guard — a media library with accounts and watch history answering
      # the internet, protected by nothing but Jellyfin's own login. Moving the entry
      # here is the whole change: proxy.nix branches on which attrset a service is in,
      # so the guard attaches, blocky repoints the name at a TAILSCALE address instead
      # of kelpy's public IP, and the DNS generator drops its AAAA and its proxy flag.
      #
      # ⚠ THE DNS RECORDS DO NOT FOLLOW A DEPLOY. parts/apps/dns reads this registry but
      # is pushed separately — `nix run .#dns -- push` — so until that runs the name
      # still resolves to the public IP and every off-tailnet client gets the help page
      # rather than a refusal. That is the right failure (403, not a hang), but it is
      # not the end state.
      #
      # ⚠ TRANSCODING IS SOFTWARE-ONLY AND ~3.3x SLOWER HERE. Measured 2026-09-27:
      # 1080p->720p h264 ran 12.4x realtime on kelpy (EPYC) vs 3.8x on rk1b (RK3588).
      # rk1b has VPU nodes but no usable path: the only exposed encoder
      # (rk3588-vepu121-enc) does JPEG and nothing else, and the H.264/HEVC decoders are
      # stateless V4L2 which mainline ffmpeg cannot drive. Hardware transcode would need
      # the vendor BSP kernel plus jellyfin-ffmpeg built --enable-rkmpp. Fine while
      # clients direct-play; revisit if transcodes become common.
      jellyfin = {
        edge = "kelpy";
        port = 8096;
        origin = "rk1b";
      };
      # LiteLLM — the fleet's model gateway. Moved off kelpy to rk1b for memory: it was
      # ~292M on a 4G host and holds no state, so it is the cheapest thing to relocate.
      # Caddy still fronts it at litellm.<domain>, so consumers see no change.
      # DEPLOY BOTH HOSTS.
      #
      # `about` is a plain HTML page Caddy serves itself, saying which models are reachable,
      # on whose hardware, and why those and not better ones. The model list is currently an
      # experiment rather than a set of sensible defaults, so it needs the explanation more
      # than most services do — and being served by the edge rather than proxied, it answers
      # even when rk1b is down.
      #
      # `atRoot` puts it on `/` too. That is safe HERE specifically: LiteLLM's root is only
      # its Swagger UI, and nothing automated goes there — agents hit /v1/… directly, so the
      # only visitor to the bare hostname is a person wondering what this is. `rootAt` hands
      # the Swagger UI back at /api-docs (Caddy rewrites to `/` upstream) so it is moved
      # rather than deleted; it has no other route, as /docs 404s on this build.
      litellm = {
        edge = "kelpy";
        port = 4000;
        origin = "rk1b";
        about = {
          page = ../modules/nixos/profiles/litellm-about.html;
          atRoot = true;
          rootAt = "/api-docs";
        };
      };
      monitoring = {
        edge = "kelpy";
        port = 3001;
        origin = "rk1b";
      };
      paperless = {
        edge = "kelpy";
        port = 28981;
      };
      # Immich — the personal photo library (replaces the Google Photos/Drive
      # archive). Same edge/origin split as Navidrome and Stump: it RUNS on rk1b
      # (media node, NVMe /var/cache), fronted by kelpy's Caddy at photos.<domain>
      # behind the internal_only tailnet guard.
      #
      # It started co-located on kelpy and had to move: kelpy has 4G and no swap,
      # and immich-server peaks ~1.4G importing geodata on first start. It
      # OOM-looped there and the kernel took tuwunel and jellyfin with it. rk1b has
      # 32G and the media disk. Moving `origin` means BOTH hosts need deploying —
      # kelpy for the vhost, rk1b for the service (the same trap stump.nix flags).
      # Named `photos`, not `immich`: the registry attribute name IS the vhost subdomain
      # (proxy.nix) AND the generated DNS record (parts/apps/dns) AND the uptime probe name
      # (ADR-0019), so it is the user-facing URL rather than an implementation detail. Immich
      # is the software; photos is the service. Renaming this key moves all three together —
      # which also means a rename needs `nix run .#dns -- push`, not just a deploy.
      photos = {
        edge = "kelpy";
        port = 2283;
        origin = "rk1b";
      };
      # qBittorrent's WebUI, published out of the gluetun netns. Moved to rk1b with the
      # rest of custom.profiles.media — chiefly to get the torrent write IO off kelpy's
      # shared VPS disk (the same resource-abuse flag that moved monitoring, ADR-0021)
      # and onto the NVMe. Egress still goes through ProtonVPN inside gluetun, so the
      # home line carries the traffic but not the identity.
      torrent = {
        edge = "kelpy";
        # 8090, not qBittorrent's usual 8080: on rk1b the supernote server already holds
        # 0.0.0.0:8080 (and 8081), so gluetun died with "listen tcp4 :8080: bind: address
        # already in use". This is the HOST-side published port only — the container's
        # own WebUI stays on webuiPort 8080 inside gluetun's netns.
        #
        # ⚠ `checkPorts` below could not catch this. It compares registry entries against
        # each other on a listener host, and supernote is deliberately absent from the
        # registry because it is not Caddy-fronted — so a collision with a non-registry
        # listener is invisible to it and only shows up as a failed unit after a deploy.
        port = 8090;
        origin = "rk1b";
      };
      # affine is disabled for now (custom.profiles.affine.enable = false, so no
      # backend) — keep it out of the registry so Caddy doesn't front a dead vhost
      # and the uptime watcher doesn't probe/alert on it. Re-add when re-enabled.
      # affine = {
      #   edge = "kelpy";
      #   port = 3010;
      # };
      # Home Assistant. It RUNS on rk1a (the voice node, ADR-0027), but is fronted by
      # kelpy's Caddy (TLS via Cloudflare DNS-01 + the internal_only tailnet guard).
      # `edge` is the edge (kelpy: where DNS points and Caddy runs); `origin` is the
      # upstream Caddy reverse-proxies to over tailscale. Reachable tailnet-only at
      # home.<domain>. Flip `origin` only after HA is verified up on the new node, so
      # Caddy never proxies to a dead upstream (ADR-0027 migration ordering).
      home = {
        edge = "kelpy";
        port = 8123;
        origin = "rk1a";
      };
      # Navidrome — the friends' shared music platform (ADR-0027). Same edge/origin
      # split as Home Assistant: it RUNS on rk1b (media node, library on the NVMe /var/cache),
      # fronted by kelpy's Caddy at music.<domain> with TLS + the internal_only tailnet
      # guard. The vhost subdomain is this attribute name, so it's `music` (not
      # `navidrome`); the profile that runs it is custom.profiles.navidrome.
      music = {
        edge = "kelpy";
        port = 4533;
        origin = "rk1b";
      };
      # Music Assistant — the library-plane brain + Party guest queue (ADR-0031). Same edge/origin
      # split as Navidrome: it RUNS on rk1b (media node), fronted by kelpy's Caddy at ma.<domain>
      # with TLS + the internal_only tailnet guard. This is the HOST's control UI (login the MA
      # admin `provisioner`); the Party *guest* QR uses MA's own access mechanism, not this vhost.
      # The profile that runs it is custom.profiles.music-assistant; port is MA's web/API port.
      ma = {
        edge = "kelpy";
        port = 8095;
        origin = "rk1b";
      };
      # Stump — the reading catalog over the git-annex document library (ADR-0031, #113).
      # Same edge/origin split as Navidrome: it RUNS on rk1b (media node, corpus on the NVMe
      # /var/cache/library), fronted by kelpy's Caddy at library.<domain> with TLS + the
      # internal_only tailnet guard. Deploy BOTH hosts or the tailnet gets a TLS error.
      #
      # This vhost is the BROWSE path. It was written as the Supernote's OPDS delivery path too
      # (#114), on the assumption the device could not join the tailnet — it can (ADR-0031,
      # revision 2026-08-17), so the device now pulls from rk1b DIRECTLY at
      # `http://rk1b.<tailnet>:10001/opds/v1.2/catalog`. Going through here would hairpin a book
      # stored on rk1b out to kelpy (a VPS) and back, gated by home upstream; measured, a 23MB
      # epub crawled. Both paths stay open and both are Basic-auth'd by Stump; see
      # docs/runbooks/supernote-koreader-opds.md.
      #
      # The vhost subdomain is this attribute name, so it's
      # `library`; the profile that runs it is custom.profiles.stump. Port is Stump's own default.
      library = {
        edge = "kelpy";
        port = 10001;
        origin = "rk1b";
      };
      # slskd — the Soulseek client that seeds the shared music library outward
      # (ADR-0028). It RUNS on rk1b, inside the ProtonVPN container's netns, with its
      # web UI published out of gluetun; kelpy's Caddy fronts it tailnet-only at
      # slskd.<domain> (internal_only guard). The profile that runs it is
      # custom.profiles.media.slskd.
      #
      # Moving it here is the one relocation that DELETES work rather than shifting it:
      # on kelpy it read a full git-annex `music` REPLICA that existed solely to feed it,
      # and rk1b already holds the authoritative library at /var/cache/music. The replica
      # and its assistant are retired in hosts/kelpy/git-annex.nix, and music-sync's drain
      # into the beets inbox becomes a local move instead of a cross-host rsync.
      # Forgejo — the private forge for NEW private projects (palimpsest#204). Unlike almost
      # everything else in this block it is CO-LOCATED with the edge: it runs on kelpy, so
      # there is no `origin` and Caddy proxies to 127.0.0.1. The vhost subdomain is this
      # attribute name, so it is `forge`; the profile that runs it is custom.profiles.forge.
      #
      # 3000 is Forgejo's own default HTTP port and is free on kelpy (checked against the
      # live listener set, not just against this registry — see the `torrent` note below for
      # why that distinction matters). Git-over-SSH is NOT here: it is not an HTTP endpoint,
      # Caddy does not front it, and it would collide in `checkPorts` with nothing anyway.
      # Its port lives on custom.profiles.forge.sshPort.
      #
      # Monitored by default (ADR-0019), which is what we want: it is probed through Caddy at
      # forge.<domain>, so the probe covers the vhost, the TLS cert and the backend together.
      forge = {
        edge = "kelpy";
        port = 3000;
      };
      # Vaultwarden — the operator's self-hosted password vault (users#32, ticket users#39).
      # CO-LOCATED with the edge like the forge: it runs on kelpy, so there is no `origin`
      # and Caddy proxies to 127.0.0.1. The vhost subdomain is this attribute name, so it is
      # `vault` (not `vaultwarden`) — the same software/URL split photos/immich and
      # music/navidrome already use; the profile that runs it is custom.profiles.vaultwarden.
      #
      # 8222 is Vaultwarden's own default port and is free on kelpy — checked against the
      # LIVE listener set (`ss -lntp`, 2026-10-06), not just against this registry, which is
      # the distinction the `torrent` note above explains the hard way.
      #
      # Monitored by default (ADR-0019), which is what we want: probed through Caddy at
      # vault.<domain>, so one probe covers the vhost, the TLS cert and the backend. A vault
      # noticed as down only when a login fails is noticed too late.
      vault = {
        edge = "kelpy";
        port = 8222;
      };
      slskd = {
        edge = "kelpy";
        port = 5030;
        origin = "rk1b";
      };
    };
  };

  # Collision check keys on the host that actually LISTENS on the port — the
  # origin when the service runs off-edge (e.g. Home Assistant on rk1a),
  # otherwise the edge it is co-located with.
  # Both from the shared accessor (self.lib.serviceRoutes), which is the ONE place that
  # knows an entry declares either a `port` or a `paths` attrset. Four files used to decide
  # that for themselves; property#10 item 3 and parts/checks/service-routes.
  inherit (self.lib.serviceRoutes) listenerHost portsOf;
  endpointsOf =
    svcs:
    lib.flatten (
      lib.mapAttrsToList (_: svc: map (p: "${listenerHost svc}:${toString p}") (portsOf svc)) svcs
    );
  allServiceEndpoints = (endpointsOf services.public) ++ (endpointsOf services.private);

  uniqueEndpoints = lib.unique allServiceEndpoints;

  # An entry with BOTH `port` and `paths`, or neither, used to be accepted differently by
  # each consumer instead of failing — ports counted here, routed by prefix in Caddy,
  # probed twice, or contributing nothing anywhere. Refused at the source.
  shapeErrors = self.lib.serviceRoutes.shapeViolations (services.public // services.private);

  checkPorts =
    if shapeErrors != [ ] then
      builtins.throw "Malformed service registry entries in settings.nix:\n  ${builtins.concatStringsSep "\n  " shapeErrors}"
    else if builtins.length uniqueEndpoints != builtins.length allServiceEndpoints then
      builtins.throw "Duplicate ports found on the same listener host in settings.nix! Endpoints: ${builtins.toJSON allServiceEndpoints}"
    else
      services;
in
{
  flake.settings = {
    # MEASUREMENT MONTH (started 2026-11-10). Exactly TWO open models, one per hardware
    # tier under consideration, so a month of real traffic answers three questions that
    # benchmarks cannot: what would owning this have cost, would the output have been
    # good enough, and does the bigger box buy anything.
    #
    #   qwen3.8-27b             → the ~32 GB GPU  (20.88 GB at Q5_K_XL)
    #   nemotron-3.5-super-vl   → the 128 GB box  (86.91 GB at Q4_K_XL)
    #
    # Deliberately absent: DeepSeek-V4, GLM-5.3, Kimi K3, MiniMax, Qwen3-Coder-480B.
    # They are better models, and renting one would invalidate the experiment, because
    # no home box can run them. OpenRouter is the ONLY external provider here besides
    # Anthropic, by choice — it reaches both tiers under one account, takes no markup on
    # inference, and alone lets the quantization be pinned per request. Lyceum was
    # evaluated and rejected: 10x the input price on the one model both carry ($0.40 vs
    # $0.039 per M) and it lacks the model it was considered for.
    #
    # Two validity caveats to remember when reading the results. No provider serves
    # GGUF, so each entry pins the served tier nearest the quant we would run — fp8 for
    # the 27B, nvfp4 for Nemotron — making quality here an UPPER bound, tighter for
    # Nemotron than for the 27B. And this cannot measure prefill latency at all: a
    # provider's datacentre GPU is not our card, and prefill is the main hardware risk.

    # ── THE MODEL CATALOGUE ───────────────────────────────────────────────────────────────
    # Every model the fleet can reach, in ONE place, because three consumers need the same
    # list and keeping three copies did not work: LiteLLM routes these names
    # (profiles/litellm.nix), and both agents must be told which names exist before they
    # will offer them — hermes in its `providers:` block, opencode in its `provider.litellm`
    # block. Neither agent discovers the list reliably (hermes' picker fetch and opencode's
    # catalogue probe are separate credential paths from the chat call), so each one carried
    # a hand-written copy.
    #
    # ⚠ THEY DRIFTED THE FIRST DAY. opencode's copy was written without
    # `nemotron-3.5-super-vl`, so its picker offered the three Claude models and one other
    # and read as an Anthropic-only provider, while hermes' copy had all five. Nothing
    # fails when these disagree: each agent happily offers exactly what its own list says.
    # Deriving all three from here is what makes that class of bug impossible rather than
    # merely unlikely.
    #
    # `chat` is what the agents filter on. A model that is not a conversational endpoint —
    # `whisper` transcribes audio — belongs in LiteLLM's routing table but must never be
    # offered as a session model, because picking it would produce a session that cannot
    # answer. `litellm_params` and `model_info` are passed through to LiteLLM verbatim.
    models = {
      # Qwen3.8-27B (dense, 27B, Apache 2.0). UD-Q5_K_XL = 20.88 GB, the quality knee;
      # the most-downloaded model on the Hub and the one practitioners actually name.
      # The `provider` block is what makes the rent a fair proxy for the self-host:
      # fp8 only, no silent fallback to a cheaper quant, zero data retention, and
      # require_parameters so an endpoint that cannot do tool calls is skipped rather
      # than quietly dropping them.
      "qwen3.8-27b" = {
        chat = true;
        litellm_params = {
          model = "openrouter/qwen/qwen3.8-27b";
          api_key = "os.environ/OPENROUTER_API_KEY";
          extra_body.provider = {
            # The quant pin is the experiment's validity constraint and is NOT
            # negotiable. Fallbacks are ALLOWED but only within that pinned pool, so a
            # busy provider is routed around rather than failing the call. That
            # distinction matters more than it looks: with fallbacks off, a measured
            # upstream 429 fired the agent's Sonnet fallback — which would have recorded
            # "the open model failed the task" when the truth was "a provider was
            # rate-limited", quietly poisoning the one number this month exists to
            # produce. (That agent-side fallback belonged to the retired openclaw
            # profile; Hermes has no primary/fallback for the main turn, so if the
            # behaviour is wanted back it belongs in `litellm_settings.fallbacks`
            # here — where the spend metric would record it directly.) Ten fp8 endpoints serve this model (Chutes, Near AI, Wafer,
            # PrimeIntellect, Mancer, Tenstorrent, Reka, AkashML, Parasail, CoreWeave),
            # so the pool is deep. `require_parameters` also earns its place: CoreWeave
            # and SiliconFlow advertise some models without tool support and are
            # excluded automatically rather than silently dropping tool calls.
            quantizations = [ "fp8" ];
            allow_fallbacks = true;
            require_parameters = true;
            data_collection = "deny";
            zdr = true;
          };
        };
      };

      # THE 128 GB TIER. Nemotron 3.5 Super VL, 120B total / 12B active, OpenMDW-1.1.
      # UD-Q4_K_XL = 86.91 GB, which is the point: it does NOT fit 32 GB, so it is the
      # only thing here that actually distinguishes the two boxes. nvfp4 is pinned
      # rather than fp8 because 4-bit is the tier closest to the ~4.2 bits/weight we
      # would run locally — BETTER validity than the 27B above, not worse.
      #
      # Read this one as a FLOOR for the tier, not a ceiling. The model a 128 GB owner
      # would really run is Qwen3.8-Flash-Next (24 of 95 Strix-Halo HN comments; next
      # best is 7), and on NVIDIA's OWN published numbers Nemotron loses to it badly:
      # SWE-bench Pro 51.78 vs 60.37, Terminal-Bench 2.1 60.67 vs 85.80. Flash-Next is
      # effectively unrentable — not served per-token by DeepInfra, Together, Novita,
      # Nebius, SiliconFlow, Parasail, Chutes, DashScope, Hyperbolic, Baseten or
      # OpenRouter; Fireworks lists it dedicated-GPU-only; and Lyceum, reported as the
      # one per-token source, does NOT carry it — its catalogue has 12 models and the
      # "$0.20/$0.50" attributed to Flash-Next is GLM-5.3-Flash's price, verified on
      # Lyceum's own pricing page. Beware the near-miss generally: `qwen3.8-flash` is
      # Alibaba's separate MANAGED SKU, not this architecture, and several providers
      # resell it while quoting Flash-Next's spec sheet.
      #
      # So the honest reading of a month of data: if Nemotron measures no better than
      # the 27B above, that is evidence the 128 GB tier buys nothing — note its
      # SWE-bench Pro 51.78 roughly equals Muse-Glimmer-30B's 51.2 at 15.88 GB. If it
      # measures clearly better, the tier is worth a second look with a real engine,
      # because Flash-Next would beat this.
      "nemotron-3.5-super-vl" = {
        chat = true;
        litellm_params = {
          model = "openrouter/nvidia/nemotron-3.5-super-vl";
          api_key = "os.environ/OPENROUTER_API_KEY";
          extra_body.provider = {
            quantizations = [ "nvfp4" ];
            allow_fallbacks = true;
            require_parameters = true;
            data_collection = "deny";
            zdr = true;
          };
        };
      };

      # ── A REJECTED ROUTE, AND A JOB THAT DOES NOT EXIST ────────────────────────────────
      # An EU-pinned route (OVHcloud, Gravelines-only, no prompt retention) was considered
      # and DROPPED: ~EUR 7.46/mo against ~EUR 1.58 for the same model via OpenRouter.
      # The decision stands and is worth keeping; what it was decided FOR does not.
      #
      # ⚠ IT WAS WEIGHED FOR A "NIGHTLY LOG REVIEW" THAT WAS NEVER BUILT. The job belonged
      # to the retired openclaw profile, and nothing replaced it: hermes has run with ZERO
      # jobs since it was deployed, and no ticket for a log review exists. Until this
      # comment was corrected (2026-11-16) it asserted in the present tense that "the
      # nightly review ships hostnames, IPs and service topology to whichever fp8 provider
      # OpenRouter picks" — describing a live privacy exposure from a job that has never
      # run once. A comment that reasons carefully about a phantom reads as evidence the
      # phantom is real.
      #
      # WHAT IS ACTUALLY TRUE about geography, so the next reader has the live version:
      # the two OPEN models above are served by whichever fp8/nvfp4 provider OpenRouter
      # picks, anywhere; the three Claude models go DIRECT to Anthropic since 2026-11-16.
      # `zdr` and `data_collection = deny` bound retention on the OpenRouter half, never
      # geography. Nothing scheduled sends fleet logs anywhere today, because nothing
      # scheduled exists.
      #
      # So this becomes live only when some agent job starts feeding logs to an open model.
      # If one is ever built, re-run this trade then — the price gap is the same, but the
      # thing being protected would at last be real. See ADR-0041 and `docs/agent-jobs.md`.

      # The baseline to beat, kept as three entries rather than one so a consumer can pick
      # by weight: Haiku for summarising, Sonnet for agent work, Opus only where it earns
      # 2x. (This used to name the nightly log review as Haiku's job. That job does not
      # exist — see the correction above.)
      #
      # ⚠ THE KEY IS USER-SCOPED, SO EVERY REQUEST NEEDS THE WORKSPACE HEADER. It is an
      # `sk-ant-usr…` key, not `sk-ant-api…`, and Anthropic refuses it bare: "this API key is
      # not scoped to a workspace, so this request must include the anthropic-workspace-id
      # header". LiteLLM's anthropic route does not add that on its own, so it is passed
      # here. The id names the org's Default workspace and is an identifier, not a
      # credential — useless without the key, which stays in sops.
      #
      # THE OUTAGE THIS CAME OUT OF, because the error text misleads. On 2026-11-16 all
      # three returned "Your credit balance is too low to access the Anthropic API", which
      # reads as overspend. It was not: the Oct 15 $100 Max credit had **expired**, and the
      # replacement key being user-scoped hid the fact that a fresh $100 granted Nov 8 was
      # already sitting there. Both halves had to be found before this route came back.
      #
      # ⚠ THE CURRENT CREDIT EXPIRES 2026-12-11. The same lapse takes these three models
      # down again on that date, and with them anything defaulting to one. OpenRouter serves
      # all three (`openrouter/anthropic/claude-*`) and is the two-line escape per entry.
      "haiku-5.5" = {
        chat = true;
        litellm_params = {
          model = "anthropic/claude-haiku-5-5";
          api_key = "os.environ/ANTHROPIC_API_KEY";
          extra_headers."anthropic-workspace-id" = anthropicWorkspace;
        };
      };

      "sonnet-5.5" = {
        chat = true;
        litellm_params = {
          model = "anthropic/claude-sonnet-5-5";
          api_key = "os.environ/ANTHROPIC_API_KEY";
          extra_headers."anthropic-workspace-id" = anthropicWorkspace;
        };
      };

      "opus-5.5" = {
        chat = true;
        litellm_params = {
          model = "anthropic/claude-opus-5-5";
          api_key = "os.environ/ANTHROPIC_API_KEY";
          extra_headers."anthropic-workspace-id" = anthropicWorkspace;
        };
      };

      whisper = {
        chat = false;
        litellm_params = {
          model = "deepinfra/openai/whisper-large-v3";
          api_key = "os.environ/DEEPINFRA_API_KEY";
        };
        model_info = {
          mode = "audio_transcription";
        };
      };
    };

    admin.email = "admin@${primaryDomain}";
    inherit primaryDomain;
    mailDomain = primaryDomain;

    # The tailnet's MagicDNS suffix (tailscale-assigned, stable). Every fleet host is
    # reachable at `<hostName>.${tailnet}`, resolved live by blocky's ts.net forward
    # (ADR-0021/0023). Monitoring scrape targets, Gatus raw-TCP probes, and Caddy
    # upstreams use these NAMES instead of pinned tailscale IPs — which silently rot
    # when a host re-keys (the porcupineFish scrape breakage). Only consumers that
    # structurally need an IP literal (HA trusted_proxies) and the deliberately-pinned
    # Vector receiver (ADR-0022) still read nodes.*.tailscale.ip4.
    tailnet = "tail8596c.ts.net";

    # Fleet SSH host keys, rendered into programs.ssh.knownHosts by profiles/base.nix.
    #
    # PUBLIC data — a host key exists to be published — so it lives here in the open repo
    # rather than the secrets stash, and deliberately NOT in secrets/nodes.nix, which is
    # scoped to the handful of tailscale IPs that must be literals.
    #
    # Why declare them at all when MagicDNS already resolves every host: MagicDNS answers
    # "what address is rk1b", not "is the machine answering there the one I meant". The
    # second question is SSH's, and unanswered it stops any host-to-host command at a
    # first-contact prompt — which is what broke an rsync from kelpy to rk1b even though
    # the name resolved fine. The git-annex remotes never hit it only because that module
    # manages its own .ssh for the git-annex user, so the gap stays invisible until
    # something else tries.
    #
    # Each entry covers the bare name, its lowercase MagicDNS form (tailscale lowercases,
    # so `sawtoothShark` is `sawtoothshark` on the tailnet) and the FQDN. Addresses are
    # deliberately absent: the fleet addresses hosts by name precisely so a re-key cannot
    # rot a pinned IP (see secrets/nodes.nix).
    #
    # To add a host: `ssh <host> cat /etc/ssh/ssh_host_ed25519_key.pub`. Re-keying a host
    # (a reflash regenerates it) means updating it here, or every peer refuses it — loudly,
    # which is the point.
    hostKeys = {
      kelpy = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFxYh9E9CSKCUmX3XrYdAWF3+z0lf6E8XKdP0H1mFWkd";
      rk1a = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF6JzPAATadOmBGkzcjFEeyDfSGPXMn7c2a2T748oSvX";
      rk1b = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8vcWJlfVAx0p384OZniUuuo66oYnC9XlPaeajMZtTM";
      porcupineFish = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPB1Szi8Wcy14xVp8t1dldg7zeRcjuUFN2Im+d2MExsq";
      sawtoothShark = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICKpf3TlWKUf4U2JlOQqY43sJ0T/Q3stMfiz6uz9qWr";
      # weedySeadragon and potbelliedSeahorse are absent because they were
      # powered off when this was populated, not because they are excluded. Add them with
      # the command above; an absent host simply keeps the old first-contact prompt.
    };

    # Mail domains served by Stalwart — the single source of truth consumed by both the
    # kelpy mail profile and the `dns` app (which generates the per-domain mail records).
    mail = {
      domain = primaryDomain;
      extraDomains = [ "palebluebytes.xyz" ];
    };

    # The tailnet's fleet DNS resolvers: the hosts running blocky that are registered
    # as tailscale global nameservers (ADR-0023). Single source of truth for the
    # `tailscale-dns` app, which resolves each host's CURRENT tailscale IP and pushes
    # the admin-console nameserver list — self-healing against the reflash IP-drift
    # that silently killed the old porcupineFish secondary. Keep in sync with the
    # `custom.profiles.blocky.enable` grants in hosts/default.nix.
    dns.nameserverHosts = [
      "kelpy"
      "rk1b"
    ];

    # blocky's HTTP port: its API and, since `prometheus.enable` is on, its `/metrics`
    # endpoint (blocky.nix). Declared here rather than in the profile because the
    # monitoring server scrapes resolvers it does not itself build (server.nix), so it
    # has no config to read the port back off.
    dns.httpPort = 4001;

    # `presence` is a host's operational cadence (GLOSSARY.md → Always-on / On-demand
    # host): `always-on` runs 24/7, `on-demand` runs only when in use. It is plumbed
    # into the node scrape targets as a label (server.nix) so a host's monitoring
    # alert-worthiness is *derived* — an on-demand host being unreachable is expected,
    # never a fault, so it never colours a fleet health signal red.
    #
    # `onTailnet` is the separate question of whether the node is REGISTERED on the
    # tailnet and so has a MagicDNS name (`<hostName>.${tailnet}`) at all. Defaults to
    # true — nearly every node is — and only a node running no tailscale sets it false.
    # It is not a monitoring policy either: the `node` scrape job addresses targets BY
    # MagicDNS name (server.nix), so a node without one is not an unreachable target but
    # an *unresolvable* one. MagicDNS SERVFAILs a name it does not own and blocky's
    # conditional upstream has nothing to fall back to, so every such scrape is counted
    # as a resolver error — silently, since blocky does not log an upstream SERVFAIL
    # (palimpsest#165, where one undeclared node produced ~16% of rk1b's query errors).
    # Do NOT conflate it with `presence`: an on-demand host that is merely powered off
    # still HAS a MagicDNS name, still resolves, and is *meant* to read `up == 0`
    # (ADR-0026). The value is tied back to each host's real `services.tailscale.enable`
    # by the host_fleet_coherence check, so it cannot drift from the machine it describes.
    #
    # `diskFloorGiB` is the host's declared minimum free space, in GiB, on any real
    # filesystem it owns (ADR-0032). It has two consumers and is deliberately ONE number: the nix
    # daemon's mid-build emergency GC uses it as `min-free` (profiles/nixConfig.nix), and
    # the disk-space watcher alerts when a device sits under it (monitoring/disk-space.nix).
    # So it reads as a single claim — "this host must never have less than X free" — that
    # the machine both defends and reports on.
    #
    # The values are MEASURED, not guessed, from 48 days of retained node_filesystem_*
    # history; monitoring/disk-space-backtest.py re-derives them from VictoriaMetrics and
    # should be re-run before changing any of them. What the measurement settled:
    #
    #   * A percentage threshold is unusable on this fleet. Devices span 29 GiB to 451 GiB,
    #     so the same percentage means wildly different risk — at 80%, sawtoothShark still
    #     has ~90 GiB free while rk1a has 5.8 GiB and is one build from death. Backtested,
    #     a flat >=80% rule had sawtoothShark in alarm for 441 of its 498 observed hours.
    #   * A free-SPACE floor separates the real squeezes from the comfortable devices
    #     cleanly: every genuinely dangerous episode in the window sat under ~10 GiB free,
    #     and no comfortable device ever did.
    #   * The floor cannot be fleet-wide either. rk1b's SD card idles at 13.6 GiB free
    #     quite happily, so a 15 GiB floor would have alarmed on it for 930 of 1155 hours,
    #     while sawtoothShark needs tens of GiB just to build a system closure.
    nodes.kelpy = {
      hostName = "kelpy";
      domain = "palebluebytes.space";
      presence = "always-on";
      # 90 GiB vpsAdminOS container. Dipped to 9.2 GiB free once in the window.
      diskFloorGiB = 5;
      tailscale = {
        ip4 = getMeta "kelpy" [ "tailscale" "ip4" ] "100.64.0.1";
        ip6 = getMeta "kelpy" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::1";
      };
      public = {
        ip4 = getMeta "kelpy" [ "public" "ip4" ] "0.0.0.0";
        ip6 = getMeta "kelpy" [ "public" "ip6" ] "::1";
      };
    };

    # These hosts are scrape targets by MagicDNS name (server.nix makeTargets) and Gatus
    # probe targets by name — neither needs a pinned tailscale IP. Only kelpy (HA
    # trusted_proxies + Caddy edge) and rk1b (Vector receiver, ADR-0022) keep a
    # `tailscale` block, for the consumers that structurally need an IP literal.
    nodes.porcupineFish = {
      hostName = "porcupineFish";
      presence = "always-on";
      # 117 GiB card, ~100 GiB free and near-flat (it moved 3.5 points in 48 days).
      diskFloorGiB = 5;
    };

    nodes.sawtoothShark = {
      hostName = "sawtoothShark";
      presence = "on-demand";
      # The fleet's builder: 451 GiB ext4 root, and the one host that needs tens of GiB
      # free just to realise a system closure. It spent 441 of 498 observed hours above
      # 80% used while perfectly healthy, and its one real incident bottomed out at
      # 9.3 GiB free — which is why this is a space floor and not a percentage.
      diskFloorGiB = 20;
    };

    nodes.weedySeadragon = {
      hostName = "weedySeadragon";
      presence = "on-demand";
      # UNMEASURED: on-demand and off for the whole retention window, so it published no
      # filesystem series to backtest against. Holds the fleet default until it does.
      diskFloorGiB = 5;
    };

    # RETIRED 2026-08-21: `potbelliedSeahorse`, the nebula lighthouse. Its config is kept
    # (hosts/potbelliedSeahorse/, modules/nixos/profiles/nebula.nix) and still builds, but it
    # is no longer fleet MEMBERSHIP — nothing addresses, scrapes, probes or labels it. It had
    # gone quiet without anyone noticing: absent from the tailnet AND from the LAN (an ARP
    # sweep found every other machine and no second Pi), silent on its own lighthouse address
    # 192.168.100.1, `up == 0` for the whole 3-month retention window, and holding no age key
    # in secrets/identities.nix — so sops installs nothing on it and it could not decrypt the
    # nebula certs its one role needs even if it did boot. It is also the only host that ever
    # enabled `nebula`, and its mesh lists no other members: a lighthouse for an empty mesh.
    # To bring it back, restore an entry here (`onTailnet` false unless it gains tailscale) —
    # the host_fleet_coherence check will hold the declaration to the machine.

    nodes.rk1a = {
      hostName = "rk1a";
      presence = "always-on";
      # The tightest host on the fleet: a 29 GiB eMMC card that spent 141 hours under
      # 5 GiB free and bottomed out at 1.9 GiB. The floor is deliberately not raised to
      # match — at 10.5 GiB free today it would then alert permanently, which is a
      # capacity problem to fix on the host, not a threshold to tune around.
      diskFloorGiB = 5;
    };

    nodes.rk1b = {
      hostName = "rk1b";
      presence = "always-on";
      # Three devices: a 29 GiB SD card that idles at 13.6 GiB free, plus the NVMe pair
      # (/nix and /var/cache) which never dropped below 69 GiB. The SD card is why the
      # floor stays at 5 — see the rk1b note in the header.
      diskFloorGiB = 5;
      tailscale = {
        ip4 = getMeta "rk1b" [ "tailscale" "ip4" ] "100.64.0.5";
        ip6 = getMeta "rk1b" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::5";
      };
    };

    services = checkPorts;

    # Hosts that run the Caddy edge profile (proxy.nix). The ADR-0019 uptime
    # watcher probes a service's HTTPS vhost through Caddy when its edge is listed
    # here, else falls back to a raw TCP probe to the listener; the slice-04 guard
    # uses the same notion to decide whether a monitored service is probeable.
    # Extend when a second host runs the edge.
    caddyEdges = [ "kelpy" ];
  };
}
