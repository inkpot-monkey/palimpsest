{
  config,
  lib,
  settings,
  pkgs,
  self,
  ...
}:

let
  cfg = config.custom.profiles.proxy;
  inherit (settings.admin) email;

  # Seconds a browser is told to refuse plaintext for. Named here rather than inlined so
  # the ramp is one edit against one number; the reasoning for the value, and the steps
  # to raise it by, are at the `(cloudflare_tls)` snippet that uses it.
  hstsMaxAge = 86400;

  # The page the tailnet guard serves to a request from outside the tailnet, as a
  # directory because `file_server` serves a root rather than a file. Kept as real
  # HTML in its own file and NOT inlined into the Caddyfile below: a Caddyfile parses
  # `{` as the start of a placeholder, so every CSS rule in an inlined page would have
  # to be escaped, and `caddy adapt` reports that as a config error a long way from the
  # brace that caused it. A file also means the copy can be edited and reviewed as
  # copy, by someone not reading Nix.
  helpRoot = pkgs.writeTextDir "index.html" (builtins.readFile ./tailnet-help.html);

  # A service may ship a human-readable page explaining itself, served at `/_about` on its
  # own vhost (see `about` in parts/settings.nix). Same file-not-inlined reasoning as
  # helpRoot above, plus two substitutions so the page can date itself: a hand-maintained
  # review date lives in the copy, and these two say when the CONFIG last moved. When the
  # second is far ahead of the first, the page has drifted from what it describes — which
  # is the failure mode a static page has, made visible instead of silent.
  #
  # `self.rev` is absent on a dirty tree, so both fall back rather than failing the build.
  aboutRoot =
    file:
    pkgs.writeTextDir "index.html" (
      builtins.replaceStrings
        [ "@REV@" "@LASTMOD@" ]
        [
          (self.rev or "dirty")
          (self.lastModifiedDate or "unknown")
        ]
        (builtins.readFile file)
    );

  # The index for a path-routed vhost (`paths` in parts/settings.nix — today only
  # `boards`, property#8). GENERATED FROM THE REGISTRY, never hand-written: a hand-kept
  # list is a second source of truth and would drift the first time a board is added or
  # retired, which is exactly the kind of quiet wrongness this vhost exists to avoid.
  #
  # Served by Caddy itself rather than by one of the backends, for the same reason the
  # `about` pages are: it answers when every board behind it is down, which is when
  # someone most wants to know what was supposed to be here. That is also why it must
  # NOT be the only thing probed — see the per-path probes in monitoring/watcher.nix.
  #
  # The link text is the prefix with its slash removed rather than a `label` key on the
  # registry entry: a name nobody has to remember to keep accurate cannot go stale.
  indexRoot =
    name: paths:
    pkgs.writeTextDir "index.html" ''
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>${name}</title>
      <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.5 system-ui, sans-serif; margin: 0;
               display: grid; place-content: center; min-height: 100vh; padding: 2rem; }
        main { max-width: 32rem; }
        h1 { font-size: 1.3rem; margin: 0 0 .25rem; }
        p { color: #6b6560; margin: 0 0 1.5rem; }
        ul { list-style: none; padding: 0; margin: 0; }
        li { border-top: 1px solid #8884; }
        a { display: block; padding: .8rem .2rem; text-decoration: none;
            color: inherit; font-weight: 600; }
        a:hover { background: #8881; }
      </style>
      </head>
      <body>
      <main>
      <h1>${name}</h1>
      <p>Pages the fleet's agent jobs produce, so a human can look at what they found.</p>
      <ul>
      ${lib.concatMapStringsSep "\n" (p: ''<li><a href="${p}/">${lib.removePrefix "/" p}</a></li>'') (
        lib.attrNames paths
      )}
      </ul>
      </main>
      </body>
      </html>
    '';
in
{
  options.custom.profiles.proxy = {
    enable = lib.mkEnableOption "Caddy reverse proxy configuration";
  };

  config = lib.mkIf cfg.enable {
    sops = {
      secrets.cloudflare_dns_token = {
        sopsFile = self.lib.getSecretPath "profiles/networking.yaml";
        owner = "caddy";
        group = "caddy";
      };
      templates.caddy_env = {
        content = "CLOUDFLARE_API_TOKEN=${config.sops.placeholder.cloudflare_dns_token}";
        owner = "caddy";
        group = "caddy";
      };
    };

    services.caddy = {
      enable = true;
      inherit email;
      # ⚠ THE HASH FOLLOWS CADDY'S VERSION, NOT THE PLUGIN'S. This is the vendor hash of
      # caddy's Go module set WITH the plugin added, so a nixpkgs bump of caddy invalidates
      # it even though the plugin pin below has not moved — and the failure arrives as a
      # `nixpkgs` bump breaking the EDGE, several steps from its cause:
      #   caddy-src-with-plugins → caddy → Caddyfile-formatted → etc → toplevel
      # Last seen 2026-11-09 on caddy 2.11.4 → 2.11.9.
      #
      # To re-derive after a bump: build and take the `got:` hash from the mismatch. Nothing
      # unpinned is being accepted — the caddy version comes from the locked nixpkgs and the
      # plugin is pinned to a tag — so the new value is a function of the two pins, not of
      # whatever upstream happens to serve today.
      package = pkgs.caddy.withPlugins {
        plugins = [ "github.com/caddy-dns/cloudflare@v0.2.1" ];
        hash = "sha256-88e3zkffSC9RgOA1OtNKRakrbOxoNA5Kl1u9tFeozI0=";
      };
      globalConfig = "";
      extraConfig = ''
        # ── THE TAILNET GUARD ─────────────────────────────────────────────────────────
        # Every private service's only access control. 80/443 are open on ALL interfaces
        # (below), because the public services need them — so this matcher, not the
        # firewall, is what keeps forge, vault, photos and the rest off the internet.
        #
        # ⚠ THE GUARD MUST BE INSIDE A `handle`, AND THAT IS NOT A STYLE CHOICE. It was a
        # bare `abort @not_internal` until 2026-10-06 and did nothing whatsoever:
        # `handle` sorts AHEAD of `abort` in Caddy's directive order, and each vhost's own
        # `handle { reverse_proxy … }` carries no matcher — so it matched every request and
        # terminated the route chain before the abort was ever reached. Measured with
        # `caddy adapt` on both forms:
        #
        #   bare abort:        route[0] subroute        match=ALL          ← reverse_proxy
        #                      route[1] static_response match=not remote…  ← dead code
        #   abort in a handle: route[0] subroute        match=not remote_ip
        #                      route[1] subroute        match=ALL
        #
        # Confirmed live before the fix: a request from a PUBLIC source address to
        # vault/forge/library/photos (right Host + SNI, against kelpy's public IP) was
        # served 200. This matcher is now the WHOLE of the protection, with no obscurity
        # behind it: until 2026-10-09 a private service's published A record was kelpy's
        # TAILSCALE address, so the names did not resolve usefully from the internet, and
        # that accident was doing some of the work. The records point at kelpy's PUBLIC
        # address now (parts/apps/dns) so that the help page below has a reachable
        # listener to be served from — which also means every private name resolves and
        # completes TLS from anywhere, and only this matcher stands between that and the
        # service. Nothing was really given up: Caddy requests a per-vhost Let's Encrypt
        # certificate, and every one of those names was already published in the public
        # Certificate Transparency logs.
        #
        # It serves a PAGE rather than `abort`ing because the audience is a non-technical
        # friend on a phone who has let Tailscale drop (ADR-0027 — the tailnet is not
        # single-person). `abort` closes the connection with no response, which a phone
        # renders as an unexplained browser error and the friend reads as "it is broken".
        #
        # 403 and not 200, because the ADR-0019 uptime probes assert `[STATUS] < 500`
        # (monitoring/watcher.nix) and resolve through blocky to a TAILSCALE address, so
        # they pass this matcher and never see this page. 403 keeps it that way should one
        # ever resolve publicly: it stays under 500, so a help page cannot start reporting
        # a service as healthy, and cannot start alerting for a service that is fine.
        #
        # Two `handle` blocks are mutually exclusive, and Caddy SORTS them — it does not keep
        # their written order. Measured on 2.11.4 while building
        # parts/checks/caddy-internal-guard, which is also where the cases are pinned:
        # `handle /b` before `handle /a` adapts to `/a, /b`, and a matcher-less catch-all
        # always sorts LAST. The guard carries a matcher and every vhost's own handle is a
        # catch-all, so the guard wins wherever the import is written.
        #
        # ⚠ This corrects what this comment said until then — that written order is kept, so the
        # import "has to be" first. It is first below, and that reads well, but nothing depends
        # on it: believing otherwise means believing a guard moved below the handle would be a
        # hole, and it would not. What a hole DOES require is the guard losing the sort
        # altogether, which is what a bare `abort` did. The check asserts the resolved order
        # from `caddy adapt` rather than either of these claims, and it holds a passing case for
        # the late import so that a future Caddy honouring written order fails loudly instead of
        # making this paragraph quietly wrong again.
        (internal_only) {
          @not_internal {
            not remote_ip 100.64.0.0/10 127.0.0.1 ::1 fd7a:115c:a1e0::/48
          }
          handle @not_internal {
            # `rewrite` collapses every path onto the one page, so a deep bookmark
            # (…/album/123) explains itself instead of 404ing. no-store because the
            # answer depends on where the visitor is, not on the URL: a cached copy
            # would survive them connecting and reloading.
            root * ${helpRoot}
            rewrite * /index.html
            header Cache-Control "no-store"
            file_server {
              status 403
            }
          }
        }

        # ── TLS POLICY ────────────────────────────────────────────────────────────────
        # Despite the name, this snippet now carries BOTH halves of a vhost's TLS story:
        # how the certificate is obtained, and what the browser is told to do with it.
        # They live together deliberately. Every Caddy vhost in the fleet must import
        # this to get a certificate at all — proxy.nix's generator, matrix/default.nix
        # and mail/default.nix's four — so a vhost that serves HTTPS cannot be built
        # while forgetting the header. A separate `(hsts)` snippet would read better and
        # be forgotten exactly once, on exactly the vhost nobody re-reads. This repo has
        # already paid for that shape once: see the tailnet guard above, which was
        # present, looked right, and did nothing.
        #
        # WHAT HSTS BUYS. 80 and 443 are open on all interfaces and every name resolves
        # publicly (see the guard above), so a first request typed as `http://` or
        # followed from an old link crosses the network in plaintext before the redirect
        # answers. On a hostile network that request can be answered by someone else and
        # proxied, with the victim kept on HTTP throughout — they see a working page and
        # no padlock. This header moves the upgrade inside the browser: after one
        # successful HTTPS response, `http://` is rewritten before a packet leaves the
        # machine, and cert warnings for the name stop being click-through-able.
        #
        # ⚠ MAX-AGE IS A PROMISE HELD BY THE CLIENT, AND IT CANNOT BE WITHDRAWN. It lives
        # in each visitor's browser for its full duration; serving `max-age=0` only
        # reaches browsers that still complete a TLS handshake. So the value is the
        # window during which a TLS failure becomes a hard, unbypassable outage for
        # everyone who has visited — and this fleet lost DNS-01 renewal for a month
        # without noticing (blocky's customDNS swallowing non-A types), which is the
        # precise failure this would have converted into an outage. One day is the
        # opening value for that reason, not because a day is the right answer: it covers
        # the realistic strip window while capping the blast radius at 24h.
        #
        # RAMP IT HERE, deliberately and one step at a time, once renewal has gone a few
        # cycles untouched: 86400 → 604800 (a week) → 31536000 (a year). Check
        # `docs/holds.md`-style evidence first — that certs actually reissued, not that
        # nothing alerted, since the renewal outage was green on every board.
        #
        # NO `includeSubDomains`: every name here is a leaf (music.<domain>, not
        # a.music.<domain>), so it would claim authority over nothing that exists while
        # pre-committing any future sub-name to working TLS before it is built. The apex
        # is where it would mean something, and the apex is not served by Caddy at all —
        # it resolves to a Cloudflare Worker (see the NOTE on virtualHosts below), so
        # apex HSTS is a Cloudflare-side setting and not this file's to make.
        #
        # NO `preload`: that bakes the domain into browsers' shipped lists, takes months
        # to undo, and is the one knob here with no local rollback whatsoever.
        (cloudflare_tls) {
          tls {
            dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          }
          header Strict-Transport-Security "max-age=${toString hstsMaxAge}"
        }
      '';
      environmentFile = config.sops.templates.caddy_env.path;

      virtualHosts =
        let
          allServices =
            (lib.mapAttrs (_: svc: svc // { isPublic = true; }) settings.services.public)
            // (lib.mapAttrs (_: svc: svc // { isPublic = false; }) settings.services.private);
          hostServices = lib.filterAttrs (
            _: svc: svc.edge == config.networking.hostName && (svc.proxy or true)
          ) allServices;
        in
        # NOTE: the apex (${domain}) is intentionally NOT served here — it resolves to a
        # Cloudflare Worker (see the apex ALIAS in parts/apps/dns/dnsconfig.ts), so apex
        # traffic never reaches Caddy.
        lib.mapAttrs' (
          name: svc:
          let
            # Most services are co-located with Caddy (proxy to loopback). A service may
            # instead run on another node and set `origin`, in which case Caddy proxies
            # to that node over tailscale by MagicDNS name (resolved live, not a pinned IP;
            # e.g. Home Assistant on rk1a). DNS still points at this (edge) host, so the
            # service stays tailnet-only behind internal_only.
            upstream = if svc ? origin then "${svc.origin}.${settings.tailnet}" else "127.0.0.1";
          in
          lib.nameValuePair "${name}.${config.networking.domain}" {
            extraConfig = ''
              ${lib.optionalString (!svc.isPublic) "import internal_only"}
              import cloudflare_tls
              ${lib.optionalString (svc ? about) (
                let
                  a = svc.about;
                  # `/_about` is the stable permalink and always present. `atRoot` ALSO puts
                  # the page on `/`, which is only right where the app's own root page is
                  # expendable — a human typing the bare hostname wants to know what the
                  # service is, and an agent never goes there (it hits /v1/… directly).
                  paths = [ "/_about" ] ++ lib.optional (a.atRoot or false) "/";
                in
                ''
                  # Served by Caddy itself, NOT proxied — so it answers even when the
                  # upstream is down, which is exactly when someone wants to know what this
                  # host was supposed to be serving. Matched handles sort ahead of the
                  # catch-all below; the tailnet guard still sorts ahead of all of them,
                  # which parts/checks/caddy-internal-guard asserts rather than assumes.
                  #
                  # These are EXACT paths, not prefixes: Caddy's `path` matcher is exact
                  # without a trailing `*`, so `/` here cannot swallow `/ui/` or `/v1/…`.
                  @about path ${lib.concatStringsSep " " paths}
                  handle @about {
                    root * ${aboutRoot a.page}
                    rewrite * /index.html
                    header Cache-Control "no-store"
                    file_server
                  }
                ''
                + lib.optionalString (a ? rootAt) ''
                  # Taking `/` would otherwise DELETE whatever the app served there. This
                  # hands it back at a new path by rewriting to `/` upstream, so nothing is
                  # lost — only moved. For LiteLLM that is its Swagger UI, which has no
                  # other route (/docs is a 404 on this build).
                  handle ${a.rootAt} {
                    rewrite * /
                    reverse_proxy ${upstream}:${toString svc.port}
                  }
                ''
              )}
              ${
                if svc ? paths then
                  # ── ONE NAME, SEVERAL BACKENDS (property#8) ────────────────────────
                  # A path-routed vhost: one `handle <prefix>*` per entry in `paths`,
                  # each to its own process, plus a generated index on the catch-all.
                  #
                  # `handle` and NOT `handle_path`: the prefix is FORWARDED, not
                  # stripped. The app is told its own base path and owns the whole URL
                  # space, so what the browser asks for is what the process sees.
                  # Stripping would leave each board emitting links into a URL space it
                  # cannot observe — and it would still have to be told the prefix in
                  # order to emit them, so it buys nothing and adds a second coordinate
                  # system to debug. See `--base-path` in property-board.py.
                  #
                  # `<prefix>*` with no slash before the star deliberately matches both
                  # `/property` and `/property/…`: a human types the bare prefix, and a
                  # 404 there would read as a dead board.
                  #
                  # Each of these is a MATCHED handle, so it sorts ahead of the
                  # catch-all index below and behind the tailnet guard above — the same
                  # ordering the `about` pages rely on, asserted rather than assumed by
                  # parts/checks/caddy-internal-guard.
                  lib.concatStringsSep "\n" (
                    lib.mapAttrsToList (prefix: port: ''
                      handle ${prefix}* {
                        reverse_proxy ${upstream}:${toString port}
                      }
                    '') svc.paths
                  )
                  + ''

                    # The index, generated from the registry and served by Caddy itself
                    # so it answers even with every board down. Catch-all rather than an
                    # exact `/` match on purpose: a mistyped or retired board prefix then
                    # lands on the list of the ones that exist instead of a bare 404.
                    handle {
                      root * ${indexRoot name svc.paths}
                      rewrite * /index.html
                      header Cache-Control "no-store"
                      file_server
                    }
                  ''
                else
                  ''
                    handle {
                      reverse_proxy ${upstream}:${toString svc.port}
                    }
                  ''
              }
            '';
          }
        ) hostServices;
    };

    # Open firewall ports
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        config.services.caddy.dataDir
      ];
    };
  };
}
