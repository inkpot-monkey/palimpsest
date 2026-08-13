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
# ── The credential (one sops secret) ──────────────────────────────────────────────────────
# Stump's server-owner account. The server grants owner rights to the FIRST account registered on
# an empty database and then refuses unauthenticated registration, so this is the one credential
# that exists — and it is what the provisioning oneshot below uses to create the three libraries.
#
# Lives in the shared `profiles/library.yaml` bundle (this stack's secret file, shared with the
# Supernote server and the ereader reconciler) under a `stump` sub-map alongside `supernote:`:
#   stump:
#     user: reader                 # any username; unlike Supernote's, it need not be an email
#     password: your-password
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
  # and the edge host (kelpy) where Caddy fronts it at library.<domain> under internal_only.
  svc = settings.services.private.library;

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
            # Only the edge and the tailnet can reach the port at all, but the server still logs
            # the client address per request — with trust on, that is the real client, not Caddy.
            STUMP_VERBOSITY = "1";
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
          # Read the corpus through the tree's sharing group — Stump never writes it. This is the
          # membership that PrivateUsers would silently break (see the mkForce below).
          extraGroups = [ cfg.group ];
        };
        users.groups.stump.gid = 979;

        systemd.services.stump = {
          # The corpus roots must exist before the scanner (and before the provisioner, which refuses
          # to create a library whose path is missing).
          after = [ "stump-library-roots.service" ];
          requires = [ "stump-library-roots.service" ];
          serviceConfig = {
            # THE TRAP. Upstream sets PrivateUsers = true. Inside that user namespace only root and
            # the service's own uid/gid are mapped, so every SUPPLEMENTARY group — including the
            # `library` membership above — maps to the overflow id (nobody/65534). The corpus tree is
            # mode 2770 git-annex:library, so Stump loses its read path into it and every library scans as
            # empty: no error, no crash, just a permanently empty catalog. Forcing it off is what
            # makes the group membership real. (The alternative, SupplementaryGroups= inside the
            # namespace, still needs the gid mapped, so it does not help.) Verified red→green in the
            # `stump` VM check, which reads a real 2770 git-annex:library tree.
            PrivateUsers = lib.mkForce false;
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
        sops.secrets."stump/user" = {
          sopsFile = self.lib.getSecretFile "library";
          key = "stump/user";
          owner = "stump";
        };
        sops.secrets."stump/password" = {
          sopsFile = self.lib.getSecretFile "library";
          key = "stump/password";
          owner = "stump";
        };

        systemd.services.stump-provision = {
          description = "Bootstrap the Stump owner account and the three series-priority libraries";
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
          };
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = "stump";
            Group = "stump";
            # Credentials land in a per-service tmpfs (CREDENTIALS_DIRECTORY), never argv or environ.
            LoadCredential = [
              "user:${config.sops.secrets."stump/user".path}"
              "password:${config.sops.secrets."stump/password".path}"
            ];
            ExecStart = pkgs.writeShellScript "stump-provision" ''
              set -euo pipefail
              export STUMP_USER_FILE="$CREDENTIALS_DIRECTORY/user"
              export STUMP_PASSWORD_FILE="$CREDENTIALS_DIRECTORY/password"
              exec ${pkgs.python3}/bin/python3 ${./stump-provision.py}
            '';
          };
        };
      }
    ]
  );
}
