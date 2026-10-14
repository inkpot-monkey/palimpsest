{
  self,
  pkgs,
  ...
}:

# The tailnet guard's ROUTE ORDER (palimpsest#218's deferred follow-up).
#
# `internal_only` in modules/nixos/profiles/proxy.nix is the whole of the access control on every
# private service: 80/443 are open on all interfaces because the public services need them, and
# since 2026-10-09 every private name resolves to kelpy's PUBLIC address so the help page has a
# reachable listener. Nothing is behind this matcher but the matcher.
#
# It silently did nothing for an unknown period. A bare `abort @not_internal` loses to the vhost's
# own matcher-less `handle { reverse_proxy … }`, because `handle` sorts AHEAD of `abort` in Caddy's
# directive order — so the proxy terminated the route chain and the abort was dead code behind it.
# vault, forge, library and photos all served 200 to a request from a public source address.
#
# WHY A CHECK AND NOT A COMMENT. #218 fixed it and closed saying nothing asserts the order, so it
# can rot back silently — and the reason it can is specific: **the ADR-0019 uptime probes cannot
# see this**. They resolve through blocky to a tailscale address, so they pass the matcher and get
# the service either way. A regression here is green on every board the fleet has. The failure mode
# is also the worst available: not an outage, but the credential store answering the internet.
#
# WHAT IT ASSERTS, and the first point is the one that matters. It runs `caddy adapt` — Caddy's own
# Caddyfile-to-JSON transform, the same thing the server does at startup — so the subject is
# Caddy's RESOLVED order, never the order the directives were written in. That distinction IS the
# bug: the broken form looked right in the Caddyfile.
#
#   1. in every private vhost, NOTHING THAT CAN TERMINATE THE CHAIN PRECEDES THE GUARD — stated
#      as: the guard is the first `subroute`, and anything ahead of it is non-terminal middleware
#      from an explicit allowlist. It matches `not remote_ip` over a range set including the
#      tailnet's 100.64.0.0/10.
#
#      "route[0]" is what #218 wrote down and it is too strong: `paperless` legitimately has a
#      `request_body` + `encode` route ahead of its guard (profiles/paperless.nix appends them
#      with mkAfter, and Caddy sorts both ahead of `handle`). Those are MIDDLEWARE — they set a
#      body limit and wrap the writer, then call the next handler — so the guard still decides
#      whether anything is served. A `subroute` ahead of it would not be: that is precisely the
#      shape of the bug, since both the guard and a service's `handle` become subroutes and the
#      first one to match and terminate wins. The allowlist is deliberately a list rather than a
#      rule about terminality, so a new handler type appearing ahead of the guard has to be
#      thought about by a human once. (One known, accepted consequence: a public request with a
#      body over paperless's 100M limit gets a 413 from that middleware instead of the help
#      page. It reveals that something is listening, and serves nothing.)
#   2. every public vhost has NO such guard anywhere in it — the generator branches on `isPublic`,
#      and a guard leaking onto jellyfin would 403 the internet;
#   3. every private service in the registry actually HAS a vhost, because "no unguarded route"
#      is vacuously true of a vhost that was never generated.
#
# The expectation is re-derived from `settings.services.{public,private}` rather than read back out
# of `services.caddy.virtualHosts`, so this tests the generator instead of agreeing with it.
#
# AND IT PROVES IT CAN FAIL. The synthetic cases at the end feed `caddy adapt` the shapes this guard
# is meant to reject — the historical bare `abort`, no guard at all, and a matcher that lost its
# `not` (which serves the internet and blocks the tailnet, and looks fine) — and assert the
# predicate says no. Without them a predicate that had quietly become unfalsifiable would pass the
# real fleet forever and read exactly like a working check. That is the same argument
# parts/checks/backup-targeting makes for handing an assertion a bad config.
#
# One of those cases is a PASSING one and it earned its place by correcting this repo: see case 4,
# which pins the measured fact that Caddy sorts matcher-less handles last regardless of written
# order — the opposite of what proxy.nix's comment claimed when this check was written.
#
# No VM: `caddy adapt` is a pure transform and the whole contract is (config text) -> (JSON order),
# so a derivation is the right shape. It does build the fleet's plugin-bearing caddy.

let
  inherit (pkgs) lib;

  # The range that makes the matcher mean "on the tailnet". Additions are fine — a host may want
  # another CIDR — but losing this one silently un-gates everything, so it is what gets asserted
  # rather than the whole list.
  tailnetRange = "100.64.0.0/10";

  edges = lib.filterAttrs (
    _: host: host.config.custom.profiles.proxy.enable or false
  ) self.nixosConfigurations;

  # The registry's own answer to "which vhosts should exist here, and which must be guarded" —
  # the same filter proxy.nix applies, restated so the two have to agree.
  vhostsFor =
    host: kind:
    let
      hostName = host.config.networking.hostName;
      wanted = lib.filterAttrs (
        _: svc: svc.edge == hostName && (svc.proxy or true)
      ) self.settings.services.${kind};
    in
    map (n: "${n}.${host.config.networking.domain}") (lib.attrNames wanted);

  perEdge = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: host: ''
      echo
      echo "── ${name}: adapting the generated Caddyfile with the fleet's own caddy"
      ${host.config.services.caddy.package}/bin/caddy adapt \
        --config ${host.config.services.caddy.configFile} --adapter caddyfile \
        > ${name}.json 2>${name}.adapt.err \
        || { echo "FAIL: caddy adapt refused ${name}'s config" >&2; cat ${name}.adapt.err >&2; exit 1; }
      echo "   $(jq '[.apps.http.servers[].routes[]] | length' ${name}.json) vhost routes"

      ${lib.concatMapStringsSep "\n" (vhost: ''
        exists ${name}.json ${vhost} || exit 1
        guarded ${name}.json ${vhost} || exit 1
      '') (vhostsFor host "private")}

      ${lib.concatMapStringsSep "\n" (vhost: ''
        exists ${name}.json ${vhost} || exit 1
        unguarded ${name}.json ${vhost} || exit 1
      '') (vhostsFor host "public")}
    '') edges
  );

  # One caddy for the synthetic cases; they use no DNS plugin, so any build does.
  caddy = (lib.head (lib.attrValues edges)).config.services.caddy.package;
in
pkgs.runCommand "check-caddy-internal-guard"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail

    # Every predicate below reads the ADAPTED json, so "first" means first to Caddy.
    # A vhost is one route matched by Host; its handlers are a subroute whose own `routes`
    # are what ordering applies to.
    inner='.apps.http.servers[].routes[] | select(.match[0].host | index($h)) | .handle[0].routes'

    # ⚠ These three REPORT by returning non-zero, never by `exit`. The synthetic cases below
    # reuse `guarded` as a predicate, and `exit` inside a function called in an `if` condition
    # terminates the whole shell — which is exactly how this harness first died, silently,
    # because the predicate's stderr was redirected away. Call sites add `|| exit 1`.
    exists() { # $1 = json, $2 = vhost
      if ! jq -e --arg h "$2" "[$inner] | length > 0" "$1" >/dev/null; then
        echo "FAIL: $2 has no vhost in the adapted config at all" >&2
        echo "  A private service with no vhost is not protected by this guard — it is absent." >&2
        return 1
      fi
    }

    # Handlers that may legitimately run BEFORE the guard: middleware that calls the next
    # handler rather than answering. Adding to this list is a decision, not a formality — see
    # the header.
    passthrough='["request_body","encode","headers"]'

    guarded() { # $1 = json, $2 = vhost
      # Reduce the vhost to its resolved route list ONCE — {match, handlers} per route, in
      # Caddy's own order — then every predicate below is plain jq over that array. Keeping the
      # extraction and the reasoning apart is deliberate: the first version inlined `$inner`
      # into a single-quoted jq program, where the shell never expanded it.
      local order
      order=$(jq --arg h "$2" "[$inner | .[] | {match, handlers: [.handle[].handler]}]" "$1")

      # Exactly one route is the guard: matching `not remote_ip <ranges including the tailnet>`.
      if ! jq -e --arg r "${tailnetRange}" '
        [ .[] | select(.match[0].not[0].remote_ip.ranges // [] | index($r)) ] | length == 1
      ' <<<"$order" >/dev/null; then
        echo "FAIL: $2 — no tailnet guard matching ${tailnetRange}, or more than one" >&2
        echo "  This vhost is reachable from the internet (palimpsest#218)." >&2
        echo "$order" >&2
        return 1
      fi

      # Nothing that can terminate the chain may precede it. Both the guard and a service's
      # `handle` adapt to `subroute`, and the first to match and terminate wins — so the guard
      # must be the FIRST subroute, and only allowlisted middleware may sort ahead of it.
      if ! jq -e --arg r "${tailnetRange}" --argjson pass "$passthrough" '
          (map(.match[0].not[0].remote_ip.ranges // [] | index($r) != null) | index(true)) as $g
        | (map(.handlers | index("subroute") != null) | index(true)) as $firstSub
        | ($g == $firstSub)
          and ([ .[:$g][] | .handlers[] | select($pass | index(.) | not) ] | length == 0)
      ' <<<"$order" >/dev/null; then
        echo "FAIL: $2 — something that can terminate the request precedes the tailnet guard" >&2
        echo "  The guard must be the first subroute, and only non-terminal middleware" >&2
        echo "  ($passthrough) may sort ahead of it. This is the palimpsest#218 shape: a" >&2
        echo "  matcher-less handle outranking the guard serves the service to the internet." >&2
        echo "$order" >&2
        return 1
      fi
      echo "   ✓ $2 — guard is the first subroute, nothing terminal ahead of it"
    }

    unguarded() { # $1 = json, $2 = vhost
      if ! jq -e --arg h "$2" \
        "[$inner | .[] | select(.match[0].not[0].remote_ip != null)] | length == 0" "$1" >/dev/null; then
        echo "FAIL: $2 is PUBLIC but carries a tailnet guard — it would 403 the internet" >&2
        return 1
      fi
      echo "   ✓ $2 public and unguarded"
    }

    ${perEdge}

    # ── Now prove the predicate can say no ────────────────────────────────────────────────
    # Each fixture is a vhost shaped like a real one: the guard snippet, then the service's own
    # matcher-less handle. Only the guard's FORM or POSITION changes.
    echo
    echo "── synthetic cases: the shapes this guard must reject"

    # $1 = name, $2 = guard form (bare|handle), $3 = import position (before|after|none).
    #
    # The form is a KEYWORD rather than the guard's text because a Caddyfile block cannot be
    # written on one line — `handle @x { respond 403 }` is a parse error — and passing the body
    # as a string invited exactly that. adapt's stderr is kept and shown, for the same reason
    # this was hard to find: a fixture that fails to parse must say so, not vanish.
    fixture() {
      {
        echo '{'
        echo '  auto_https off'
        echo '}'
        echo '(internal_only) {'
        echo '  @not_internal {'
        echo "    not remote_ip ${tailnetRange} 127.0.0.1"
        echo '  }'
        case "$2" in
          bare)
            # The 2026-10-06 shape: `handle` sorts ahead of `abort`, so this loses.
            echo '  abort @not_internal'
            ;;
          handle)
            echo '  handle @not_internal {'
            echo '    respond 403'
            echo '  }'
            ;;
          inverted)
            # The matcher without its `not`: tailnet users get the help page and the internet
            # falls through to the service. Catastrophic, and it looks almost identical.
            echo '  @internal {'
            echo "    remote_ip ${tailnetRange} 127.0.0.1"
            echo '  }'
            echo '  handle @internal {'
            echo '    respond 403'
            echo '  }'
            ;;
          *) echo "unknown guard form: $2" >&2; exit 1 ;;
        esac
        echo '}'
        echo 'svc.example.test {'
        # `if`, not `[ … ] && echo`: under `set -e` an AND-list whose test is false fails the
        # whole script, which is how this function first died with no message at all.
        if [ "$3" = before ]; then echo '  import internal_only'; fi
        echo '  handle {'
        echo '    reverse_proxy 127.0.0.1:9999'
        echo '  }'
        if [ "$3" = after ]; then echo '  import internal_only'; fi
        echo '}'
      } > "$1.caddyfile"
      ${caddy}/bin/caddy adapt --config "$1.caddyfile" --adapter caddyfile \
        > "$1.json" 2> "$1.err" \
        || { echo "FAIL: fixture '$1' is not a valid Caddyfile, so it tests nothing" >&2
             cat "$1.err" >&2; cat "$1.caddyfile" >&2; exit 1; }
    }

    expect_rejected() { # $1 = name, $2 = description
      if guarded "$1.json" svc.example.test >/dev/null 2>&1; then
        echo "FAIL: the predicate ACCEPTED $2 — it cannot detect the regression it exists for" >&2
        jq '[.apps.http.servers[].routes[] | .handle[0].routes[] | {match, handlers: [.handle[].handler]}]' "$1.json" >&2
        exit 1
      fi
      echo "   ✓ rejected: $2"
    }

    # 1. The historical bug, exactly: a bare abort, which `handle` outranks.
    fixture bare bare before
    expect_rejected bare "a bare \`abort @not_internal\` (the 2026-10-06 bug)"

    # 2. No guard at all — the shape a new private service gets if someone forgets the import.
    fixture none handle none
    expect_rejected none "no guard at all"

    # 3. The matcher with its `not` dropped. This is the one that does not look like a bug: the
    #    guard is present, in a handle, first — and inverted, so the tailnet gets the help page
    #    while the internet gets the service. Rejected because the predicate requires the
    #    `not`, not merely a remote_ip matcher.
    fixture inverted inverted before
    expect_rejected inverted "a guard whose matcher lost its \`not\` (serves the internet, blocks the tailnet)"

    # 4. ⚠ A POSITIVE case that documents a MEASURED rule, and the reason it is here is that
    #    proxy.nix used to explain the live config's safety the wrong way round. Its comment
    #    said two `handle` blocks "keep their written order, so the guarded one has to be
    #    imported BEFORE the vhost's own handle". Measured on caddy 2.11.4, that is false twice
    #    over: `handle /b` then `handle /a` adapts to `/a, /b`, so written order is NOT kept —
    #    Caddy SORTS them, and a matcher-less catch-all always sorts LAST. So the guard wins
    #    wherever the import is written, which is a stronger guarantee than the comment claimed.
    #
    #    Pinned as a passing case rather than deleted: if a future Caddy ever does honour
    #    written order, this starts failing and says so — at which point the old claim has
    #    become true and the import position starts to matter.
    fixture late handle after
    guarded late.json svc.example.test >/dev/null \
      || { echo "FAIL: a guard imported AFTER the service's handle is no longer first." >&2
           echo "  Caddy used to sort matcher-less handles last regardless of written order." >&2
           echo "  If that has changed, proxy.nix's import position now matters — read the" >&2
           echo "  comment in this file's case 4 before changing anything." >&2
           exit 1; }
    echo "   ✓ accepted: a guard imported after the service's handle (Caddy sorts catch-alls last)"

    # 5. And the positive control, so the rejections above are not just a broken predicate
    #    saying no to everything.
    fixture good handle before
    guarded good.json svc.example.test >/dev/null \
      || { echo "FAIL: the predicate REJECTED the shape the fleet runs" >&2; exit 1; }
    echo "   ✓ accepted: the shape the fleet actually runs"

    echo
    echo "SUCCESS: in every private vhost the tailnet guard is the first subroute with nothing"
    echo "         terminal ahead of it, every public vhost is unguarded, and the predicate rejects"
    echo "         a bare abort, a late import and a missing guard while accepting the live shape."
    touch $out
  ''
