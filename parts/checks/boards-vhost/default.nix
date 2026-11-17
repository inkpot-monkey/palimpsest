{
  self,
  pkgs,
  ...
}:

# The shared, path-routed `boards` vhost (forge inkpotmonkey/property#8).
#
# A *board* is a page an agent job produces so a human can look at what it found. They all
# share ONE name, path-routed — `boards.<domain>/property` — instead of spending a name,
# a DNS record, a blocky entry and a fleet-wide deploy each. A registry entry carrying
# `paths` (prefix → port) is what declares that shape, and three separate generators have
# to agree about it: proxy.nix emits the Caddy routes, proxy.nix also generates the index,
# and monitoring/watcher.nix emits the probes.
#
# ── WHY A CHECK, AND WHY THESE THREE THINGS ───────────────────────────────────────────
#
# 1. EVERY PREFIX IS ROUTED, TO ITS OWN PORT. The whole claim of this shape is "adding the
#    next board is one line and a port". That claim is only true while the generator
#    actually fans the attrset out; a `paths` entry that silently produced no route would
#    leave the board 404ing behind an otherwise healthy vhost, and nothing else here looks.
#
# 2. THE INDEX LISTS EXACTLY THE BOARDS THAT EXIST. The ticket asks for the index to be
#    generated from the registry rather than hand-written, for a stated reason: a
#    hand-written list is a second source of truth and drifts the first time a board is
#    added or retired. Asserting *exactly* (not "contains") is what makes that real — a
#    list that merely contains the right entries would pass while naming a board that was
#    deleted months ago, which is the drift the generation exists to prevent.
#
# 3. EVERY BOARD HAS ITS OWN PROBE, AND IT IS NOT THE VHOST ROOT. This is the part
#    property#8 insisted must not be deferred. The probe on `boards` itself proves Caddy,
#    the certificate and the index page — which Caddy serves ITSELF, from the store. It is
#    therefore green with every board behind it dead. A per-prefix probe is the only thing
#    that can tell those apart, and it must point at a path the BACKEND answers (/healthz)
#    rather than the prefix root, because proxy.nix deliberately answers an unknown prefix
#    with the index. Both of those are asserted, the second by pinning the condition set:
#    `[STATUS] == 200`, not the `< 500` used for a whole service, so a 404 from a retired
#    board fails instead of passing.
#
# The expectations are re-derived from `settings.services` rather than read back out of the
# generated config, so this tests the generators instead of agreeing with them. The Caddy
# side reads the ADAPTED json (`caddy adapt`, Caddy's own transform) for the same reason
# parts/checks/caddy-internal-guard does: the subject is what Caddy resolves, not what was
# written. Route ORDER — that the tailnet guard still sorts ahead of these new matched
# handles — is that check's business and not restated here.
#
# AND IT PROVES IT CAN FAIL: the index predicate is run against a page built for a
# different set of boards, and must reject it. Without that, a predicate that had quietly
# become unfalsifiable would read exactly like a working check.

let
  inherit (pkgs) lib;
  inherit (self) settings;

  domain = settings.primaryDomain;

  # Every registry entry that declares the path-routed shape, with the facts the three
  # generators each need. `public // private` because the shape is not private-only by
  # construction, even though today's only user is.
  routed = lib.filterAttrs (_: svc: svc ? paths) (
    settings.services.public // settings.services.private
  );

  upstream = svc: if svc ? origin then "${svc.origin}.${settings.tailnet}" else "127.0.0.1";

  # The Caddy edges that have to carry a routed vhost.
  edges = lib.filterAttrs (
    _: host: host.config.custom.profiles.proxy.enable or false
  ) self.nixosConfigurations;

  # The hosts running the ADR-0019 watcher — where the probes are generated.
  watchers = lib.filterAttrs (
    _: host: host.config.custom.profiles.monitoring-watcher.enable or false
  ) self.nixosConfigurations;

  # ── 1 + 2: the Caddy side, per edge ────────────────────────────────────────────────
  perEdge = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      hostName: host:
      let
        mine = lib.filterAttrs (_: svc: svc.edge == host.config.networking.hostName) routed;
      in
      lib.optionalString (mine != { }) ''
        echo
        echo "── ${hostName}: adapting the generated Caddyfile with the fleet's own caddy"
        ${host.config.services.caddy.package}/bin/caddy adapt \
          --config ${host.config.services.caddy.configFile} --adapter caddyfile \
          > ${hostName}.json 2>${hostName}.err \
          || { echo "FAIL: caddy adapt refused ${hostName}'s config" >&2; cat ${hostName}.err >&2; exit 1; }

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: svc: ''
            echo "   ${name}.${domain}:"
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (prefix: port: ''
                routed_to ${hostName}.json ${name}.${domain} '${prefix}' \
                  '${upstream svc}:${toString port}' || exit 1
              '') svc.paths
            )}
            # The index Caddy serves on the catch-all, read back out of the adapted
            # config so the page under test is the one that would actually be served.
            index_of ${hostName}.json ${name}.${domain} > ${name}.index.html || exit 1
            lists_exactly ${name}.index.html ${
              lib.concatStringsSep " " (map (p: "'${p}'") (lib.attrNames svc.paths))
            } || exit 1
          '') mine
        )}
      ''
    ) edges
  );

  # ── 3: the probe side, per watcher host ────────────────────────────────────────────
  perWatcher = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (hostName: host: ''
      echo
      echo "── ${hostName}: the generated Gatus endpoints"
      cp ${host.config.services.gatus.configFile} ${hostName}.gatus.yaml

      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: svc:
          lib.concatStringsSep "\n" (
            lib.mapAttrsToList (prefix: _: ''
              probes ${hostName}.gatus.yaml '${name}-${lib.removePrefix "/" prefix}' \
                'https://${name}.${domain}${prefix}/healthz' || exit 1
            '') svc.paths
          )
        ) routed
      )}
    '') watchers
  );

in
pkgs.runCommand "check-boards-vhost"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.yq-go
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
  }
  ''
    set -euo pipefail

    # A vhost is one route matched by Host; its handlers are a subroute whose own `routes`
    # carry the matched handles. Same extraction as parts/checks/caddy-internal-guard.
    inner='.apps.http.servers[].routes[] | select(.match[0].host | index($h)) | .handle[0].routes'

    # Predicates REPORT by returning non-zero, never by `exit` — the synthetic case at the
    # end calls one of them inside an `if`, and an `exit` there would end the whole shell.
    # Call sites add `|| exit 1`.

    routed_to() { # $1 = json, $2 = vhost, $3 = prefix, $4 = expected dial address
      # The prefix must be matched as a PREFIX (`/property*`), not exactly: a human types
      # the bare prefix with no trailing slash, and Caddy's path matcher is exact without
      # the star, so an exact match would 404 exactly the URL a person types by hand.
      if ! jq -e --arg h "$2" --arg p "$3*" --arg up "$4" "
        [ $inner | .[]
          | select((.match[0].path // []) | index(\$p))
          | .handle[] | select(.handler == \"subroute\")
          | .. | objects | select(.handler? == \"reverse_proxy\")
          | .upstreams[].dial ] | index(\$up) != null
      " "$1" >/dev/null; then
        echo "FAIL: $2 has no route matching '$3*' that proxies to $4" >&2
        echo "  A \`paths\` entry that generates no route leaves the board 404ing behind a" >&2
        echo "  vhost that is otherwise healthy, and the probe on the name cannot see it." >&2
        jq --arg h "$2" "[$inner | .[] | {match, handlers: [.handle[].handler]}]" "$1" >&2
        return 1
      fi
      echo "      ✓ $3* → $4"
    }

    index_of() { # $1 = json, $2 = vhost — prints the page served on the catch-all
      local root
      root=$(jq -r --arg h "$2" "
        [ $inner | .[] | select(.match == null or (.match | length) == 0)
          | .handle[] | select(.handler == \"subroute\")
          | .. | objects | select(.handler? == \"vars\" and has(\"root\"))
          | .root ] | first // empty
      " "$1")
      if [ -z "$root" ]; then
        echo "FAIL: $2 serves no generated index on its catch-all" >&2
        echo "  The vhost root must list the boards that exist; without it a visitor who" >&2
        echo "  types the bare name learns nothing about what is behind it." >&2
        return 1
      fi
      cat "$root/index.html"
    }

    lists_exactly() { # $1 = html, $2.. = the prefixes the registry declares
      local page="$1"; shift
      local found
      # Every href the page offers, prefix form, deduplicated and sorted.
      found=$(grep -o 'href="[^"]*"' "$page" | sed 's/href="//; s|/*"$||' | sort -u)
      local want
      want=$(printf '%s\n' "$@" | sed 's|/*$||' | sort -u)
      if [ "$found" != "$want" ]; then
        echo "FAIL: the index does not list exactly the boards the registry declares" >&2
        echo "  registry: $(echo "$want" | tr '\n' ' ')" >&2
        echo "  page:     $(echo "$found" | tr '\n' ' ')" >&2
        echo "  A list that merely CONTAINS the right boards would pass while still naming" >&2
        echo "  one that was retired — which is the drift generating it exists to prevent." >&2
        return 1
      fi
      echo "      ✓ index lists exactly: $(echo "$want" | tr '\n' ' ')"
    }

    probes() { # $1 = gatus yaml, $2 = endpoint name, $3 = expected url
      if ! yq -e "
        [ .endpoints[] | select(.name == \"$2\") ] | length == 1
      " "$1" >/dev/null 2>&1; then
        echo "FAIL: no Gatus endpoint named '$2'" >&2
        echo "  Without it the only probe on this vhost is the one on its NAME, which is" >&2
        echo "  answered by Caddy's own index page and stays green with the board dead." >&2
        yq '.endpoints[].name' "$1" >&2
        return 1
      fi
      local url conds
      url=$(yq -r ".endpoints[] | select(.name == \"$2\") | .url" "$1")
      if [ "$url" != "$3" ]; then
        echo "FAIL: '$2' probes $url, expected $3" >&2
        echo "  The probe must hit a path the BACKEND answers. proxy.nix answers an unknown" >&2
        echo "  prefix with the index, so a probe at the prefix ROOT cannot tell a live" >&2
        echo "  board from one that is gone." >&2
        return 1
      fi
      conds=$(yq -r ".endpoints[] | select(.name == \"$2\") | .conditions | join(\",\")" "$1")
      case "$conds" in
        *"[STATUS] == 200"*) ;;
        *)
          echo "FAIL: '$2' does not require a 200 (conditions: $conds)" >&2
          echo "  The fleet's default '[STATUS] < 500' passes a 404, so a retired or" >&2
          echo "  mis-prefixed board would alert nobody." >&2
          return 1
          ;;
      esac
      echo "   ✓ $2 → $3 (requires 200)"
    }

    ${perEdge}
    ${perWatcher}

    # ── Now prove the index predicate can say no ──────────────────────────────────────
    # The one predicate here that compares two independently-derived things rather than
    # asserting presence, so it is the one that can go vacuous without looking different.
    echo
    echo "── synthetic case: an index that has drifted from the registry"
    printf '%s\n' '<ul><li><a href="/property/">property</a></li>' \
                  '<li><a href="/retired/">retired</a></li></ul>' > drifted.html
    if lists_exactly drifted.html '/property' >/dev/null 2>&1; then
      echo "FAIL: the predicate ACCEPTED an index naming a board the registry does not" >&2
      echo "  declare — it cannot detect the drift it exists for." >&2
      exit 1
    fi
    echo "   ✓ rejected: an index still naming a retired board"

    # And the positive control, so the rejection above is not just a predicate saying no
    # to everything.
    printf '%s\n' '<ul><li><a href="/property/">property</a></li></ul>' > exact.html
    lists_exactly exact.html '/property' >/dev/null \
      || { echo "FAIL: the predicate REJECTED an index that matches the registry" >&2; exit 1; }
    echo "   ✓ accepted: an index that matches the registry exactly"

    echo
    echo "SUCCESS: every \`paths\` prefix is routed to its own backend, each vhost root lists"
    echo "         exactly the boards the registry declares, and every board carries its own"
    echo "         200-requiring probe at a path only the backend can answer."
    touch $out
  ''
