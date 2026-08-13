# Acceptance test for the Stump catalog profile (ADR-0031, palimpsest#113).
#
# Runs the REAL `pkgs.stump` server (not a mock) against a REAL 2770 git-annex:library corpus
# tree, behind a REAL Caddy reverse proxy, and drives the ticket's acceptance criteria:
#
#   1. THE THREE LIBRARIES. Books / Papers / Notebooks exist, each rooted at its own directory
#      under the tree, each with `libraryPattern = SERIES_BASED` — created that way by the
#      provisioner, because the pattern is immutable afterwards. And `_originals/` is indexed by
#      NOTHING: no library's path is inside it, and its planted file never becomes a catalog entry.
#
#   2. THE GROUP READ PATH — the trap this test exists for. Upstream's `services.stump` sets
#      `PrivateUsers = true`, which maps every supplementary group to the overflow id inside the
#      namespace and severs Stump's `library` membership. The corpus below is a real 2770
#      git-annex:library tree that the `stump` user can ONLY read through that group, so a Stump
#      that has lost it scans three empty libraries — no error, no crash. Asserting a planted file
#      became a catalog entry is what makes that failure visible. (Verified to discriminate: with
#      `PrivateUsers` left at upstream's `true`, subtest 4's `books == ["clocks-of-the-long-now"]`
#      fails with `[]` while every unit stays green.)
#
#   3. TAILNET-ONLY. The `client` node on the shared LAN cannot reach the catalog port directly —
#      the profile opens it on `tailscale0` only, never `openFirewall`. Proven to be the firewall
#      and not a dead server by reaching the same port over loopback on the origin.
#
#   4. THROUGH THE EDGE, WITH CORRECT SELF-REFERENCING LINKS. A real Caddy on a separate `edge`
#      node reverse-proxies `https://library.example.com` to the origin, exactly as kelpy's does.
#      The OPDS feed fetched through it must advertise `https://library.example.com/...` links —
#      not `http://<origin>:10001/...`. That is the whole point of STUMP_TRUST_PROXY_HEADERS: an
#      OPDS client traverses the catalog by following those links, so getting them wrong breaks
#      #114 before it starts. Discriminating by construction — the assertion fails without the
#      trust setting, since the feed would then carry the direct-connection host.
#
#   5. THE DB SURVIVES A RESTART. The catalog is re-served from disk, not rebuilt, and the
#      provisioner's second run takes its idempotent path (no duplicate libraries).
#
# sops is bypassed exactly as parts/checks/supernote/default.nix does: dummy age key + forced
# secret paths pointing at plain /etc files, so no real decryption happens in the sandbox.
{
  self,
  pkgs,
  inputs,
}:
let
  # The owner account the provisioner claims from the mock credential.
  owner = "reader";
  password = "catalog-secret-123";

  # A plain test dir standing in for rk1b's NVMe /var/cache/library — no git-annex, no mount here.
  libraryPath = "/var/lib/library";

  # The vhost the edge serves. Mirrors `library.<domain>` from parts/settings.nix; the point is
  # that the OPDS feed's self-links must carry THIS name and the https scheme, not the origin's.
  vhost = "library.example.com";

  # Taken from the registry rather than repeated, so the test cannot drift from the deployment.
  inherit (self.settings.services.private.library) port;

  # Real books, so the scanner has something it genuinely knows how to process — Stump dispatches
  # on content type and only handles zip/rar/epub/pdf, so a stub file would never become a catalog
  # entry and the read-path assertion would be vacuous. groff emits a valid PDF from a tiny troff
  # source without dragging in a document toolchain. `groff.perl` is required as well as `groff`:
  # nixpkgs splits the perl-implemented drivers into their own output, and `gropdf` — the one this
  # needs — is among them, so plain `groff` fails with "couldn't exec gropdf".
  book =
    name: text:
    pkgs.runCommand "${name}.pdf"
      {
        nativeBuildInputs = [
          pkgs.groff
          pkgs.groff.perl
        ];
      }
      ''
        printf '.SH\n%s\n.PP\n%s\n' ${pkgs.lib.escapeShellArg name} ${pkgs.lib.escapeShellArg text} \
          | groff -T pdf -ms > $out
      '';
in
pkgs.testers.nixosTest {
  name = "stump-catalog-test";

  nodes = {
    origin =
      { lib, ... }:
      {
        imports = [
          inputs.sops-nix.nixosModules.sops
          (self + /modules/nixos/profiles/stump.nix)
        ];

        config = {
          # The profile reads `self.lib.getSecretFile` and takes its port/edge from the service
          # registry; test nodes get neither module arg from specialArgs, so provide both here.
          # (The sopsFile `self` resolves is unused — the secret paths are forced to plain files
          # below. `settings` is the real registry, so the port under test is the deployed one.)
          _module.args.self = self;
          _module.args.settings = self.settings;

          custom.profiles.stump = {
            enable = true;
            # Point the tree at a plain test dir (no NVMe mount / git-annex module here).
            inherit libraryPath;
          };

          # The corpus tree exactly as hosts/rk1/library.nix builds it: owned by git-annex, group
          # `library` at the pinned gid, mode 2770 — NOT world-readable. Mirrored rather than
          # stubbed, because "can the stump user read this" is the subject of the test.
          users.groups.library.gid = 977;
          users.groups.git-annex = { };
          users.users.git-annex = {
            isSystemUser = true;
            group = "git-annex";
          };
          systemd.tmpfiles.rules = [ "d ${libraryPath} 2770 git-annex library -" ];

          # Satisfy the sops assertions without a real key/file, and force the two credential
          # secrets to plain files (same bypass as the #92 supernote test).
          sops.age.keyFile = "/etc/dummy-sops-key";
          sops.defaultSopsFile = pkgs.writeText "dummy-sops.yaml" "";
          sops.validateSopsFiles = false;
          sops.secrets."stump/user".path = lib.mkForce "/etc/mock-stump-user";
          sops.secrets."stump/password".path = lib.mkForce "/etc/mock-stump-password";
          environment.etc."mock-stump-user".text = owner;
          environment.etc."mock-stump-password".text = password;

          environment.systemPackages = [ pkgs.curl ];
          # Stump migrates its schema and renders PDF thumbnails on first scan.
          virtualisation.memorySize = 2048;
        };
      };

    # Stands in for kelpy: the Caddy edge DNS points at. Deliberately a real Caddy with a real
    # `reverse_proxy`, not a hand-rolled header forwarder — the behaviour under test (Caddy
    # preserves the client's Host and adds X-Forwarded-Proto) is Caddy's, so stubbing it would
    # prove nothing about the deployment.
    edge = {
      services.caddy = {
        enable = true;
        virtualHosts."https://${vhost}".extraConfig = ''
          tls internal
          handle {
            reverse_proxy origin:${toString port}
          }
        '';
      };
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    };

    # A third node on the same LAN, with no route in but the edge — the tailnet-only assertion.
    client.environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    import json
    import time

    PORT = ${toString port}
    LOCAL = f"http://127.0.0.1:{PORT}"

    BOOKS = "${libraryPath}/books"
    PAPERS = "${libraryPath}/papers"
    NOTEBOOKS = "${libraryPath}/notebooks"
    ORIGINALS = "${libraryPath}/_originals"


    def plant(directory, series, name, source):
        """Drop a book into `<root>/<series>/` — series-priority means a root's subdirectories are
        its series, the shape the corpus is curated in. Series dir 2770 and file 0640, both
        git-annex:library, so the ONLY way `stump` can read either is the group membership."""
        origin.succeed(f"install -d -o git-annex -g library -m 2770 {directory}/{series}")
        origin.succeed(f"install -m 0640 -o git-annex -g library {source} {directory}/{series}/{name}.pdf")


    def graphql(query):
        """Run a query as the owner. The session cookie the REST login mints is what authorises
        the GraphQL endpoint, so both calls share one cookie jar."""
        origin.succeed(
            f"curl -sf -c /tmp/jar -X POST {LOCAL}/api/v2/auth/login "
            "-H 'Content-Type: application/json' "
            f"""-d '{json.dumps({"username": "${owner}", "password": "${password}"})}' -o /dev/null"""
        )
        body = json.dumps({"query": query})
        raw = origin.succeed(
            f"curl -sf -b /tmp/jar -X POST {LOCAL}/api/graphql "
            f"-H 'Content-Type: application/json' -d {repr(body)}"
        )
        parsed = json.loads(raw)
        assert "errors" not in parsed, f"GraphQL errors: {parsed}"
        return parsed["data"]


    def catalog():
        """{library name: {"path": ..., "pattern": ..., "books": [...]}} straight from the server."""
        data = graphql("{ libraries { nodes { name path config { libraryPattern } media { name } } } }")
        return {
            node["name"]: {
                "path": node["path"],
                "pattern": node["config"]["libraryPattern"],
                "books": sorted(m["name"] for m in node["media"]),
            }
            for node in data["libraries"]["nodes"]
        }


    start_all()

    # The roots oneshot runs before the server, so the provisioner never meets a missing path.
    origin.wait_for_unit("stump-library-roots.service")

    # 1. The three roots + the unindexed sibling exist, owned by git-annex and setgid to `library`.
    for d in (BOOKS, PAPERS, NOTEBOOKS, ORIGINALS):
        meta = origin.succeed(f"stat -c '%U %G %a' {d}").strip()
        assert meta == "git-annex library 2770", f"expected {d} to be git-annex library 2770, got {meta}"

    # Plant the corpus BEFORE the provisioner's first scan, so the initial scan is what indexes it
    # (rather than the `watch` watcher — that is a different mechanism and a later subtest).
    plant(BOOKS, "Stewart Brand", "clocks-of-the-long-now", "${book "clocks-of-the-long-now" "A book in the Books root."}")
    plant(PAPERS, "Distributed Systems", "time-clocks-and-ordering", "${book "time-clocks-and-ordering" "A paper in the Papers root."}")
    # The annotation source. It is outside all three roots by PHYSICAL PLACEMENT, so nothing below
    # should ever surface it — no ignore glob is doing this work.
    plant(ORIGINALS, "Stewart Brand", "clocks-of-the-long-now.raw", "${book "clocks-raw" "The raw annotation source. Never indexed."}")

    origin.wait_for_unit("stump.service")
    origin.wait_for_open_port(PORT)
    # The provisioner only reaches "active" if it claimed the owner account, logged in, and created
    # all three libraries — the account/credential proof.
    origin.wait_for_unit("stump-provision.service")

    # 2. Runs as the pinned `stump` user, which is a member of the corpus group.
    assert origin.succeed("id -u stump").strip() == "979", "stump uid is not pinned to 979"
    assert "library" in origin.succeed("id -nG stump"), "stump is not a member of the library group"

    # 3. Three series-priority libraries, one per root, and none of them rooted in _originals/.
    libraries = catalog()
    assert set(libraries) == {"Books", "Papers", "Notebooks"}, f"unexpected libraries: {libraries}"
    assert libraries["Books"]["path"] == BOOKS, libraries
    assert libraries["Papers"]["path"] == PAPERS, libraries
    assert libraries["Notebooks"]["path"] == NOTEBOOKS, libraries
    for name, lib in libraries.items():
        assert lib["pattern"] == "SERIES_BASED", f"{name} is {lib['pattern']}, not SERIES_BASED"
        assert not lib["path"].startswith(ORIGINALS), f"{name} is rooted inside _originals/"

    # 4. THE GROUP READ PATH. The planted books are catalog entries, in the right library — which
    #    can only happen if the scanner, running as `stump`, could actually read a 2770 tree it
    #    reaches solely through the `library` group. With upstream's PrivateUsers=true these come
    #    back empty (see the header).
    assert libraries["Books"]["books"] == ["clocks-of-the-long-now"], libraries["Books"]
    assert libraries["Papers"]["books"] == ["time-clocks-and-ordering"], libraries["Papers"]
    assert libraries["Notebooks"]["books"] == [], libraries["Notebooks"]
    # ...and the _originals/ file is in no library at all.
    everything = [book for lib in libraries.values() for book in lib["books"]]
    assert not any("raw" in book for book in everything), f"an _originals/ file was indexed: {everything}"

    # 5. TAILNET-ONLY. A LAN peer cannot reach the catalog port; the server is demonstrably up
    #    (the origin reaches it over loopback), so the block is the tailscale0-scoped firewall.
    origin.succeed(f"curl -sf -o /dev/null {LOCAL}/api/v2/ping")
    client.fail(f"curl -s -o /dev/null --max-time 8 http://origin:{PORT}/api/v2/ping")

    # 6. THROUGH THE EDGE. Caddy's `tls internal` CA is not in the client's trust store, hence -k;
    #    what matters is the request arrives with the edge's Host + X-Forwarded-Proto, exactly as
    #    it would through kelpy.
    edge.wait_for_unit("caddy.service")
    edge.wait_for_open_port(443)
    edge_ip = edge.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()
    resolve = f"--resolve ${vhost}:443:{edge_ip}"
    client.wait_until_succeeds(
        f"curl -skf {resolve} -o /dev/null https://${vhost}/api/v2/ping", timeout=60
    )

    # The self-referencing links an OPDS client traverses by. OPDS 2.0 is where they are absolute
    # (built from the request's scheme + Host via OPDSLinkFinalizer), so it is the feed that shows
    # whether the proxy headers were honoured. Both halves discriminate: without
    # STUMP_TRUST_PROXY_HEADERS the server ignores Caddy's X-Forwarded-Proto (scheme falls back to
    # `http`) AND, believing the connection is direct, appends its own listen port to the host —
    # producing `http://${vhost}:10001/...`, which no client can follow back through the edge.
    feed = client.succeed(
        f"curl -skf {resolve} -u ${owner}:${password} https://${vhost}/opds/v2.0/catalog"
    )
    # Scoped to the vhost rather than a bare `http://` scan: an OPDS feed is full of
    # `http://opds-spec.org/...` rel values, which are identifiers, not links to follow.
    assert f"https://${vhost}/" in feed, f"OPDS feed has no https://${vhost} self-links:\n{feed}"
    assert f"http://${vhost}" not in feed, f"OPDS self-links use a non-TLS scheme:\n{feed}"
    assert f"${vhost}:{PORT}" not in feed, f"OPDS self-links leak the origin's listen port:\n{feed}"

    # OPDS 1.2 — the version #114 targets — is served through the same edge. Its links are
    # relative by construction, so it needs no scheme assertion; that it answers at all is what
    # this proves.
    client.succeed(f"curl -skf {resolve} -u ${owner}:${password} -o /dev/null https://${vhost}/opds/v1.2/catalog")

    # An unauthenticated request through the edge is refused (the catalog is not open to any
    # tailnet peer that finds the vhost).
    client.fail(f"curl -skf {resolve} -o /dev/null https://${vhost}/opds/v2.0/catalog")

    # 7. The `watch` config on each library: a file dropped into a root after the initial scan
    #    still becomes a catalog entry, which is what makes the reconciler's drops visible.
    plant(NOTEBOOKS, "Field Notes", "2026-08-13", "${book "field-notes" "A rendered notebook."}")
    with origin.nested("waiting for the watcher to index the new notebook"):
        for _ in range(60):
            if catalog()["Notebooks"]["books"] == ["2026-08-13"]:
                break
            time.sleep(3)
        else:
            raise Exception(f"the dropped notebook never appeared: {catalog()}")

    # 8. THE DB SURVIVES A RESTART, and the provisioner is idempotent (no duplicate libraries).
    origin.systemctl("restart stump.service")
    origin.wait_for_open_port(PORT)
    origin.systemctl("restart stump-provision.service")
    origin.wait_for_unit("stump-provision.service")
    after = catalog()
    assert set(after) == {"Books", "Papers", "Notebooks"}, f"provisioner duplicated libraries: {after}"
    assert after["Books"]["books"] == ["clocks-of-the-long-now"], after["Books"]
    assert after["Notebooks"]["books"] == ["2026-08-13"], after["Notebooks"]
    journal = origin.succeed("journalctl -u stump-provision --no-pager -o cat")
    assert "already present" in journal, f"the newest provisioner run re-created libraries:\n{journal}"
  '';
}
