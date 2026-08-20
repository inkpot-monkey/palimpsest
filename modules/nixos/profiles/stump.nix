# Stump — the reading catalog over the git-annex document library (ADR-0031, palimpsest#113).
# A host-agnostic profile, enabled with `custom.profiles.stump.enable = true` (rk1b, the media
# node, which is where the library tree lives). Supersedes the browse-only catalog #93 specified:
# after the OPDS pivot (#110) this is the DELIVERY path to the Supernote, not a convenience.
#
# Runs `pkgs.stump` (TEMPORARILY 0.1.6, ahead of nixpkgs — pkgs/stump, #111) through the UPSTREAM
# `services.stump` module. Everything below is the delta between that module's defaults and what
# this fleet needs; each one is load-bearing, so read the reason before dropping one.
#
# ── The three libraries ───────────────────────────────────────────────────────────────────
# Books / Papers / Notebooks, each rooted at `library/{books,papers,notebooks}` and each
# **series-priority** (`SERIES_BASED`): a library's scan pattern is IMMUTABLE after creation, so it
# has to be right the first time — which is why they are created declaratively by the provisioning
# oneshot below rather than clicked into the admin UI. One-library-per-type is the only arrangement
# that gives both type grouping and clean subject-series under folder-only curation (ADR-0031).
#
# `_originals/` (raw `.note`/`.mark`, the precious annotation source) is a SIBLING of the three
# roots, not a child of any of them — so it is excluded from every library by PHYSICAL PLACEMENT
# and needs no ignore glob. Stump stores ignore globs in its DB, so a glob would have to be re-added
# by hand after a DB rebuild; a directory that sits outside the roots cannot be forgotten. This
# profile creates that sibling alongside the roots to make the invariant real rather than aspirational.
#
# ── Reverse-proxy trust ───────────────────────────────────────────────────────────────────
# Since 0.1.2 Stump IGNORES `X-Forwarded-*` / `Forwarded` by default (a security default: an
# untrusted client could otherwise spoof its own address). Behind kelpy's Caddy that default is
# wrong in a way that is invisible until it bites: the server would read the proxy's address as the
# client's, and — worse — generate self-referencing links from the WRONG scheme/host, which is
# exactly what an OPDS client follows to traverse the catalog (#114). `STUMP_TRUST_PROXY_HEADERS`
# turns it back on. Safe here because the port is open on `tailscale0` only, so the only thing that
# can set those headers is the edge (see the firewall note below). Stump 0.1.6 has no separate
# "public URL" knob — `HostDetails` is derived per-request from `Host` + the proxy scheme header
# (apps/server/src/middleware/host.rs), which Caddy's `reverse_proxy` sets and preserves by default.
#
# ── Reading-progress sync (KOReader, #116) ────────────────────────────────────────────────
# What is read on the Nomad is reflected here, and position is read back when the book is opened
# again. Stump ships its own implementation of KOReader's sync protocol, so this is configuration
# on both ends rather than any bridging code — but it is four things that must ALL line up, and
# the integration silently does nothing if any one of them is missing.
#
#   1. THE ROUTES ARE OFF BY DEFAULT. `ENABLE_KOREADER_SYNC` (no `STUMP_` prefix — see the note at
#      the setting itself) mounts them; without it the whole router is absent and every sync call
#      404s.
#   2. BOOKS ARE MATCHED BY HASH, AND ONLY BY HASH. Stump does not implement the protocol's
#      filename strategy. `generateKoreaderHashes` is set on every library at creation, and the
#      provisioner rescans any library whose books predate it — see ensure_koreader_hashes in
#      stump-provision.py. A book with no hash answers 404 to the device's PUT.
#   3. THE DEVICE AUTHENTICATES WITH AN API KEY IN THE URL. `/koreader/{api_key}/...` is the only
#      auth that router has — Basic auth is gated on `is_opds` and does not reach it. The key is
#      DECLARED in sops rather than minted (see the credentials section below), so the URL a
#      device is pointed at is fully determined before anything runs.
#   4. THE READER MUST MATCH BY BINARY HASH, not by filename — a device-side setting, captured in
#      docs/runbooks/supernote-koreader-opds.md along with the "log in with any credentials"
#      step KOReader insists on even when the URL already carries the key.
#
# WHOSE PROGRESS IT IS. A person's own. Reading sessions are per-user, and a device syncs as the
# reader account whose key it carries, so what you read on the Nomad is what you see when you log
# into the web UI as yourself. That is the whole reason the owner account is administrative only:
# see below.
#
# WHAT CROSSES, AND WHAT DOES NOT. The percentage crosses both ways; the POSITION only crosses
# one way. Stump stores a location as an epubcfi or a page number, and KOReader pushes an
# x-pointer (`/body/DocFragment[17]/body/div.0`). Upstream's `parse_progress`
# (apps/server/src/routers/koreader/sync.rs) matches `epubcfi(…)` or an integer and treats
# anything else as an x-pointer it cannot use — its own comment says "Stump does not support
# x-pointers" — so that arm stores the percentage and nothing else. The visible consequence:
# after reading on the Nomad the web UI shows 83% and still opens the book at page one, because
# `epubcfi` is null and there is no location to restore. The reverse direction DOES work (Stump
# writes a real epubcfi and KOReader accepts it), and device-to-device round-trips intact. A push
# from the device also clears any epubcfi the web reader had written, so the two readers take
# turns rather than coexisting. All three legs confirmed on hardware 2026-08-20; the operator-
# facing version is in docs/runbooks/supernote-koreader-opds.md. Not a defect in this config and
# not fixable here — translating x-pointers is upstream work that code comment already declines.
#
# ── The accounts: one administrative owner, N readers ─────────────────────────────────────
# `stump/user` + `stump/password` are Stump's SERVER OWNER. The server grants owner rights to the
# FIRST account registered on an empty database and then refuses unauthenticated registration, so
# this is the account everything else is bootstrapped from — and it is used by the provisioning
# oneshot below and BY NOTHING ELSE. Do not log into the web UI with it, and never put it on a
# device.
#
# THE OWNER IS DELIBERATELY NOT A PERSON, for two reasons that both bite:
#   * It cannot hold a device credential safely. `enforce_permissions` returns Ok unconditionally
#     when `is_server_owner` (crates/graphql/src/data.rs), and `validate_api_key` preserves that
#     flag when it applies a key's custom permissions — and an API key is accepted as a bearer
#     token on EVERY route. So an owner's KOReader key is a full administrative credential however
#     it is scoped, sitting in a plaintext Lua file on a sideloaded Android tablet.
#   * There is exactly one owner, so a design where the primary human IS the owner has no second
#     step. With everyone a reader, the next person is one more entry in a map.
#
# EACH READER gets an account that is their whole identity here: OPDS Basic auth, the KOReader
# sync key, the reading progress, and the web-UI login. Both of their credentials are declared, so
# there is nothing to mint, bank, or carry back from a first deploy — including the sync key, which
# is imposed on Stump rather than generated by it (stump-provision.py's `impose_key` explains how
# and what it costs).
#
# Stump also serves `/opds/{api_key}/v1.2/...` for clients that cannot set a header. That route is
# deliberately NOT used: #115 proved KOReader speaks Basic auth on the real device, and a password
# is the simpler credential when one will do.
#
# It all lives in the shared `profiles/library.yaml` bundle (this stack's secret file, shared with
# the Supernote server and the ereader reconciler) under a `stump` sub-map alongside `supernote:`:
#   stump:
#     user: catalog-owner          # any username; unlike Supernote's, it need not be an email
#     password: your-password      # administrative; not for daily use
#     readers:
#       thomas:                    # the account name you log into the web UI with
#         password: another-password        # also the OPDS password typed into the reader app
#         koreader_key: stump_<short>_<long>
# Adding a person is another entry under `readers:` and a redeploy — no change here. Generate a
# key with:
#   printf '%s_%s_%s\n' stump "$(openssl rand -hex 8)" "$(openssl rand -hex 24)"
#
# ── WHY THE KEY LOOKS LIKE THAT, AND WHY THE `stump_` PREFIX STAYS ────────────────────────
# Asked and answered on 2026-08-20: the prefix is redundant-looking (it is the same six bytes on
# every key, inside a block already called `stump:`) and it is kept deliberately. Two properties
# of the value are load-bearing, for different reasons:
#
#   * THE THREE `_`-DELIMITED PARTS are required by the sync route. `api_key_middleware` parses
#     with `PrefixedApiKey::from_string`, which rejects anything that is not exactly three parts.
#     Validation then compares `short_token` verbatim and `hex(sha256(<long>))` against
#     `long_token_hash` — see `impose_key` in stump-provision.py, which is what writes those two
#     columns.
#
#   * THE `stump` PREFIX IS NOT CHECKED BY THAT ROUTE AT ALL. `api_key_middleware` never inspects
#     it and it is not part of the hash, so a key spelled `anything_short_long` would sync
#     perfectly. It is required by `handle_bearer_auth`, which gates its API-key branch on
#     `prefix() == API_KEY_PREFIX` and otherwise falls through to JWT parsing and fails.
#
#     That bearer path is the ONLY way to read back the permission set the server RESOLVED for a
#     key — `GET /api/v2/auth/me` with the key as a bearer token — and resolved-versus-recorded is
#     exactly the distinction this design turns on everywhere else: a scope on the server owner is
#     recorded and never enforced, and `resolve_permissions` intersects a key's custom set with
#     its account's. Drop the prefix and the provisioner's verification degrades from measuring
#     that set to inferring it from two things it checked separately. Six bytes buy a direct
#     assertion, so they stay.
#
# The value in sops is also, deliberately, VERBATIM what the device holds — the profile performs
# no transformation on it. That is what lets the runbook say "the URL is `…/koreader/<the sops
# value>`", lets you `curl` the secret straight at the server to test it, and is the reason there
# is no handoff file. Storing the key without its prefix and prepending one in code was rejected
# on the same grounds: it would make the secret no longer be the credential.
#
# sops files are a SEPARATE repo (stash): add the sub-map there, commit + push, then
# `nix flake update secrets` HERE before deploying rk1b — otherwise sops-install-secrets cannot
# extract `stump/user` and activation fails (AGENTS.md gotcha). The file already lists rk1b as a
# recipient (the Supernote profile reads it), so no re-keying is needed.
#
# ── BEFORE BUMPING THE VERSION: snapshot the database ─────────────────────────────────────
# Stump migrates its schema on start, and one of those migrations has already destroyed data once
# upstream (0.1.5 consolidated reading sessions and shipped an explicit backup warning). Standing
# this up fresh on 0.1.6 sidesteps that particular migration, but the NEXT one is a coin flip. So,
# on rk1b, before `nix flake update nixpkgs` lands a new `pkgs.stump` or pkgs/stump's pin moves:
#
#   systemctl stop stump
#   install -d -o stump -g stump -m 0700 /var/cache/stump/backups
#   sqlite3 /var/cache/stump/stump.db ".backup '/var/cache/stump/backups/stump-$(date +%F).db'"
#   # then deploy; if the migration eats something, stop stump and copy the snapshot back.
#
# It is deliberately a documented manual step, not a pre-start hook: an automatic snapshot on every
# start is worthless (it would be taken AFTER the previous migration and overwrite the good copy),
# and the operator needs to know a migration is happening. `pkgs.stump` is version-pinned in-repo
# precisely so this is never an unattended update.
#
# ── Placement / durability ────────────────────────────────────────────────────────────────
# The catalog DB, thumbnails and PDF cache live in `/var/cache/stump` on rk1b's NVMe subtree
# (hosts/rk1/nvme.nix) — a real block-device mount, so they survive the tmpfs-root reboot with no
# impermanence entry, exactly like Navidrome's DB. That mount is the reason for `RequiresMountsFor`
# below: without it the unit can start before the NVMe is up and quietly build a second, doomed
# catalog on the tmpfs root.
{
  config,
  options,
  lib,
  pkgs,
  self,
  settings,
  ...
}:
let
  cfg = config.custom.profiles.stump;
  # Endpoint metadata comes from the `library` service entry in settings: the port it listens on,
  # and the edge host (kelpy) where Caddy fronts it at library.<domain> under internal_only. The
  # registry attribute name IS the vhost subdomain (proxy.nix), so it is named once here and the
  # public URL below is derived from it rather than repeating the string.
  svcName = "library";
  svc = settings.services.private.${svcName};

  # Stump's own state: DB (`stump.db`), thumbnails, avatars, PDF page cache. NOT the corpus —
  # that is `cfg.libraryPath`, which Stump only ever reads.
  configDir = "/var/cache/stump";

  # The three library roots, in `libraryPath`. Attribute name = directory; value = the Stump
  # library's display name. Series-priority is applied to all three (see the header).
  roots = {
    books = "Books";
    papers = "Papers";
    notebooks = "Notebooks";
  };
  # The annotation-source sibling. Named here (rather than hardcoded in the oneshot) so the
  # "outside every root" invariant is expressed as a set difference, not a comment.
  originalsDir = "_originals";

  rootPath = dir: "${cfg.libraryPath}/${dir}";
  # `{name, path}` pairs handed to the provisioner as JSON.
  libraryPlan = lib.mapAttrsToList (dir: name: {
    inherit name;
    path = rootPath dir;
  }) roots;

  allDirs = (lib.mapAttrsToList (dir: _: rootPath dir) roots) ++ [ (rootPath originalsDir) ];
in
{
  options.custom.profiles.stump = {
    enable = lib.mkEnableOption "Stump — the reading catalog over the document library (ADR-0031)";

    libraryPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/library";
      description = ''
        Root of the git-annex document-library tree (hosts/rk1/library.nix). Stump indexes the
        `books/`, `papers/` and `notebooks/` subdirectories as three separate series-priority
        libraries; the `_originals/` sibling is deliberately NOT indexed (it sits outside all
        three roots, so no ignore glob is needed). Read-only as far as Stump is concerned.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "library";
      description = ''
        Group owning the library tree (setgid 2770, so the tree is not world-readable). The
        `stump` user joins it to READ the corpus; git-annex owns it, because only the git-annex
        user holds the fleet annex SSH key and the replicating node must own what it replicates
        (ADR-0028's ownership model, reused by ADR-0031).
      '';
    };

    owner = lib.mkOption {
      type = lib.types.str;
      default = "git-annex";
      description = ''
        User that owns the library tree — the same owner git-annex initialises it with, so the
        root-creating oneshot below converges with `git-annex-init` rather than fighting it.
      '';
    };

    publicUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${svcName}.${settings.primaryDomain}";
      defaultText = lib.literalExpression ''"https://library.''${settings.primaryDomain}"'';
      description = ''
        The origin an OPDS client reaches this catalog at — i.e. the vhost kelpy's Caddy serves,
        which modules/nixos/profiles/proxy.nix derives as `<service>.<edge's networking.domain>`.
        Used for assembling the two URLs handed to the device: the OPDS catalog, and the KOReader
        sync server (palimpsest#116). It has to match the edge, because those URLs are typed into
        a reader app. The device can equally reach rk1b directly over the tailnet, and for BOOK
        DOWNLOADS it should — see docs/runbooks/supernote-koreader-opds.md, which explains why
        the catalog entry on the Nomad names rk1b while sync, whose payloads are a few hundred
        bytes, goes through the edge for TLS and a stable name.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # `services.stump` is upstream nixpkgs, but every profile in this repo is imported into
      # EVERY host (profiles/bundle.nix), and porcupineFish builds from nixos-raspberrypi's older
      # nixpkgs, which has no such module. A definition for an undeclared option is an eval error
      # even under `mkIf false`, so the block is gated on the option existing — the same guard
      # profiles/mail/default.nix uses for `services.stalwart`. The assertion below turns the
      # gate's failure mode from "silently configures nothing" into a build error, so a host that
      # actually enables this on a stump-less nixpkgs finds out at build time.
      (lib.optionalAttrs (options.services ? stump) {
        services.stump = {
          enable = true;
          package = pkgs.stump;
          # Bind all interfaces (not the module default 127.0.0.1): kelpy's Caddy reaches this
          # over tailscale, the same edge/origin split Navidrome and Home Assistant use. The
          # tailscale0-scoped firewall rule below is what keeps it off the home LAN.
          ip = "0.0.0.0";
          inherit (svc) port;
          # DB + thumbnails + PDF cache on the durable NVMe subtree (see the header). The upstream
          # module's default is /var/lib/stump, which on rk1b is tmpfs.
          configLocation = configDir;
          environment = {
            # See the header: without this, self-referencing links (the ones an OPDS client
            # follows) are generated from the direct-connection scheme/host instead of the edge's.
            STUMP_TRUST_PROXY_HEADERS = "true";
            # Upstream's current default, pinned explicitly: this host ships its journal to
            # VictoriaLogs, so a future change to Stump's default would silently change the log
            # volume arriving there. Raise it to 2/3 only while debugging a scan.
            STUMP_VERBOSITY = "1";
            # Mount the KOReader sync router (#116). Off by default upstream, and the failure mode
            # of leaving it off is a 404 on every sync call with nothing else wrong — the routes
            # are not merged into the axum router at all unless this is true
            # (apps/server/src/routers/mod.rs). NOTE THE MISSING `STUMP_` PREFIX: unlike every
            # other key here, upstream's constant is the bare `ENABLE_KOREADER_SYNC`
            # (core/src/config/stump_config.rs), and a misspelled key is silently ignored.
            ENABLE_KOREADER_SYNC = "true";
          };
          # We manage the firewall ourselves (tailnet-scoped, below); leave `openFirewall` at its
          # default false — it would open the port on EVERY interface, including the home LAN.
          openFirewall = false;
        };
      })

      {
        assertions = [
          {
            assertion = options.services ? stump;
            message = "custom.profiles.stump is enabled but this host's nixpkgs has no `services.stump` module (the Pi hosts track nixos-raspberrypi's older nixpkgs). Pin this host to the fleet nixpkgs or drop the profile.";
          }
        ];

        # A static system user with PINNED ids. The catalog DB and its thumbnails live on persistent
        # NVMe, and an auto-allocated uid/gid reshuffle across a reboot would orphan every one of those
        # files in place — this fleet has been bitten by exactly that (see [[kelpy-uid-map-drift]]:
        # stalwart and openclaw both lost their state to it). Upstream's `users.users.stump` pins
        # nothing. 979 is free fleet-wide: the claimed ids here are gids 977 (library), 978 (music),
        # 981 (stalwart-mail), 982 (supernote), 987 (openclaw), 993 (media) and uids 982 (supernote),
        # 985 (stalwart-mail), 988 (qbittorrent), 989 (openclaw).
        users.users.stump = {
          uid = 979;
          # Read the corpus through the tree's sharing group — Stump never writes it. Whether this
          # membership survives upstream's `PrivateUsers` sandbox is the question the VM check
          # answers; see the note on the unit below.
          extraGroups = [ cfg.group ];
        };
        users.groups.stump.gid = 979;

        systemd.services.stump = {
          # The corpus roots must exist before the scanner (and before the provisioner, which refuses
          # to create a library whose path is missing).
          after = [ "stump-library-roots.service" ];
          requires = [ "stump-library-roots.service" ];
          # UPSTREAM'S `PrivateUsers = true` IS DELIBERATELY LEFT ALONE — and that is a MEASURED
          # decision, not an oversight, because the obvious reading of it is wrong. Inside the user
          # namespace the `library` gid is unmapped, so it resolves to `nobody` by NAME, which looks
          # exactly like the membership having been severed. It has not: the kernel checks file
          # access against the process's real credentials, which systemd sets from the user database
          # before the namespace is in play. The corpus stays readable.
          #
          # This matters because getting it wrong in either direction is silent. Forcing PrivateUsers
          # off "to be safe" would drop real hardening for no reason; a genuinely severed group would
          # make every library scan as EMPTY with no error, no crash and every unit green. So the
          # question is settled by evidence rather than by argument. Inside the sandbox the `stump`
          # user's groups read `979 65534` — its own gid, plus `library` (977) squashed to the
          # overflow id — and the corpus file still opens. The `stump` VM check measures exactly
          # that, and separately plants a book in a real 2770 git-annex:library tree the `stump`
          # user can reach ONLY through the group and asserts it becomes a catalog entry. Verified
          # 2026-08-13 with PrivateUsers both on and off. If a future systemd changes it, that
          # check is what fails.
          serviceConfig = {
            # systemd creates/owns /var/cache/stump for us (upstream only declares StateDirectory,
            # which lands on tmpfs here). 0700: the DB holds session tokens and password hashes.
            CacheDirectory = "stump";
            CacheDirectoryMode = "0700";
          };
          # Gate startup on the NVMe /var/cache mount. Without it, CacheDirectory= can create the
          # catalog directory on the tmpfs root before var-cache.mount lands and the real one is then
          # shadowed — the same mount race hosts/rk1/nvme.nix's header calls out.
          unitConfig.RequiresMountsFor = [
            "/var/cache"
            cfg.libraryPath
          ];
        };

        # Tailnet-only. NOT `openFirewall` (which is every interface): the port is opened on
        # `tailscale0` alone, so the only things that can reach Stump are tailnet peers and kelpy's
        # Caddy proxying in over that same tailnet. This is also what makes trusting proxy headers
        # safe — a LAN host cannot reach the port to forge one.
        networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ svc.port ];

        # Make the three roots + the `_originals/` sibling exist, owned by the tree owner and setgid to
        # the sharing group so anything the reconciler or git-annex drops in stays readable by Stump.
        # A oneshot rather than a systemd.tmpfiles rule so it can WAIT for the /var/cache NVMe mount —
        # the same reason modules/nixos/profiles/supernote.nix creates `ereader/` this way, and the
        # reason the git-annex module avoids a plain tmpfiles rule for this tree. `install -d` is
        # idempotent and applies the same owner/group/mode git-annex would, so ordering against
        # git-annex-init is immaterial: both converge on the same answer.
        systemd.services.stump-library-roots = {
          description = "Ensure the document-library roots exist (books/papers/notebooks + the _originals sibling)";
          wantedBy = [ "multi-user.target" ];
          unitConfig.RequiresMountsFor = [ cfg.libraryPath ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.coreutils}/bin/install -d -o ${cfg.owner} -g ${cfg.group} -m 2770 ${lib.escapeShellArgs allDirs}";
          };
        };

        # ── PROVISIONING ONESHOT ──────────────────────────────────────────────────────────────
        # Bootstraps the server owner from the credential secret and creates the three libraries with
        # `SERIES_BASED` set AT CREATION. This is not a convenience: Stump's scan pattern is immutable
        # once a library exists, so a library clicked into being with the wrong pattern can only be
        # fixed by deleting it (and its reading progress). Codifying it here is the same bargain the
        # Navidrome and Home Assistant provisioners strike. Idempotent + create-only: an existing
        # library is left completely untouched, so hand-made curation in the UI is never clobbered.
        #
        # It also converges each READER's account, catalog credential and KOReader sync key
        # (#114/#116) and verifies all three. That is here rather than in a unit of its own
        # because it is the same bootstrap: it needs the owner session this script already holds,
        # and splitting it out would mean logging in twice and ordering two oneshots against each
        # other for nothing.
        sops.secrets = lib.mkMerge [
          (lib.genAttrs
            [
              "stump/user"
              "stump/password"
            ]
            (key: {
              sopsFile = self.lib.getSecretFile "library";
              inherit key;
              owner = "stump";
            })
          )
          {
            # THE READERS MAP, taken as the WHOLE decrypted file. sops-nix can only extract a
            # SCALAR value — its `recurseSecretKey` ends in a `.(string)` assertion — so
            # `key = "stump/readers"` on a YAML map would make sops-install-secrets fail and
            # install NOTHING (the all-or-nothing trap in AGENTS.md). Taking `key = ""` and
            # letting the ExecStart wrapper `yq` the map out to JSON keeps the secret file a clean
            # nested map, and is the shape navidrome's user provisioning already uses here.
            #
            # NO `owner` ON PURPOSE, unlike the two above. This blob is the entire `library`
            # bundle, which also holds the Supernote server's credentials; leaving it root-only
            # means the `stump` user cannot read those at rest. systemd reads LoadCredential
            # sources as root before dropping privileges, so the unit still gets it.
            stump_readers_bundle = {
              sopsFile = self.lib.getSecretFile "library";
              key = "";
            };
          }
        ];

        systemd.services.stump-provision = {
          description = "Bootstrap the Stump owner account, the three series-priority libraries and each reader's catalog credential and sync key";
          after = [
            "stump.service"
            "stump-library-roots.service"
            "sops-install-secrets.service"
          ];
          requires = [
            "stump.service"
            "stump-library-roots.service"
          ];
          wants = [ "sops-install-secrets.service" ];
          wantedBy = [ "multi-user.target" ];
          environment = {
            STUMP_URL = "http://127.0.0.1:${toString svc.port}";
            STUMP_LIBRARIES = builtins.toJSON libraryPlan;
            # The URLs a reader points a device at are built from the EDGE, not this loopback one.
            STUMP_PUBLIC_URL = cfg.publicUrl;
            # Stump's own database. Written to for exactly one thing — imposing the declared
            # KOReader sync key on the row Stump created — which the provisioner explains at
            # length. Everything else here goes through the API.
            STUMP_DB = "${configDir}/stump.db";
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "stump";
            Group = "stump";
            # The readers map is extracted from the bundle into the unit's private tmpfs, not into
            # the world-readable store and not into the environment.
            RuntimeDirectory = "stump-provision";
            RuntimeDirectoryMode = "0700";
            # Credentials land in a per-service tmpfs (CREDENTIALS_DIRECTORY), never argv or environ.
            LoadCredential = [
              "user:${config.sops.secrets."stump/user".path}"
              "password:${config.sops.secrets."stump/password".path}"
              "bundle:${config.sops.secrets.stump_readers_bundle.path}"
            ];
            ExecStart = pkgs.writeShellScript "stump-provision" ''
              set -euo pipefail
              # `// {}` so a bundle with no `stump.readers` yields an empty map rather than
              # `null` — the provisioner then says so plainly instead of dying on a type error.
              ${pkgs.yq-go}/bin/yq -o=json '.stump.readers // {}' \
                "$CREDENTIALS_DIRECTORY/bundle" > "$RUNTIME_DIRECTORY/readers.json"
              export STUMP_USER_FILE="$CREDENTIALS_DIRECTORY/user"
              export STUMP_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/password"
              export STUMP_READERS_FILE="$RUNTIME_DIRECTORY/readers.json"
              exec ${pkgs.python3}/bin/python3 ${./stump-provision.py}
            '';
          };
        };
      }
    ]
  );
}
