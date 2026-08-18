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
#   2. THE GROUP READ PATH — the reason this test exists. Upstream's `services.stump` runs under
#      `PrivateUsers = true`, and Stump reaches the corpus only as a member of the `library` group.
#      Inside a user namespace that gid is unmapped and resolves to `nobody` by NAME, which reads
#      like the membership has been severed — and a severed membership would make all three
#      libraries scan EMPTY with no error, no crash and every unit green. The corpus below is a
#      real 2770 git-annex:library tree the `stump` user can reach ONLY through that group, and
#      the assertion is that a planted book becomes a catalog entry.
#
#      MEASURED RESULT (2026-08-13): it works. Subtest 4 re-derives it rather than asserting it —
#      a transient unit with the same identity and sandbox reports its groups as `979 65534` (its
#      own gid, plus `library` squashed to the overflow id, i.e. the appearance of a severed
#      membership) and then reads a corpus file anyway. The kernel checks access against the
#      process's real credentials, not the namespace's view of them. So the profile leaves
#      upstream's hardening ALONE; forcing `PrivateUsers = false` would have dropped real hardening
#      on the strength of a name. This test is what would catch a systemd that changes the
#      behaviour — it was also run with the force in place, and passes either way.
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
#   5. THE OPDS CATALOG CREDENTIAL (palimpsest#114). The device authenticates as a dedicated
#      non-owner account over HTTP Basic auth, which Stump accepts on OPDS 1.2 and nowhere else.
#      Nothing is minted: both halves of the credential are declared before the server starts, so
#      there is no handoff file and no state between runs — and the test asserts that absence, so
#      the retired mint/bank machinery cannot quietly come back. It pins three properties that are
#      easy to believe without evidence: that the credential resolves to exactly `[DOWNLOAD_FILE]`
#      on a non-owner account (a scope on the OWNER is recorded and never enforced, so pointing the
#      device at the owner would pass every catalog request below while holding full administrative
#      rights); that an unauthenticated request is met with a `WWW-Authenticate: Basic` challenge,
#      which is how a reader app knows to prompt; and that Basic auth does NOT work off the OPDS
#      routes, which is what makes this password safe to type into a device.
#
#      The test then behaves like the client #115 will run: through the edge over TLS, it walks the
#      feed from the catalog root down to an acquisition link — following the rels the feed itself
#      advertises rather than URLs assembled here — downloads the book and compares its digest with
#      what was planted. A real reader app on the real device is #115; this is as close as a VM
#      gets.
#
#   6. THE DB SURVIVES A RESTART. The catalog is re-served from disk, not rebuilt, and the
#      provisioner's second run takes its idempotent path (no duplicate libraries). Cross-REBOOT
#      survival is deliberately not re-proven here: on rk1b it rests on `/var/cache` being a real
#      block-device mount (hosts/rk1/nvme.nix) plus the unit's `RequiresMountsFor`, which is a
#      property of that host's config, not of this module — and `machine.reboot()` is unreliable
#      in this driver (the same trade-off parts/checks/supernote/default.nix documents). What IS
#      this module's code — the durable configLocation and the idempotent provisioner — is what
#      the restart subtest exercises.
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

  # The dedicated, non-owner account that holds the OPDS key (#114). Its password is the second
  # mock credential; the account itself is created by the provisioner.
  opdsUser = "opds";
  opdsPassword = "opds-secret-456";

  # A plain test dir standing in for rk1b's NVMe /var/cache/library — no git-annex, no mount here.
  libraryPath = "/var/lib/library";

  # The vhost the edge serves. Mirrors `library.<domain>` from parts/settings.nix; the point is
  # that the OPDS feed's self-links must carry THIS name and the https scheme, not the origin's.
  vhost = "library.example.com";

  # Taken from the registry rather than repeated, so the test cannot drift from the deployment.
  inherit (self.settings.services.private.library) port;

  # Real books (so the scanner has something it knows how to process) and the catalog helpers,
  # both shared with parts/checks/supernote/mirror.nix — the other check that stands a real Stump
  # up over this tree.
  stump = import (self + /parts/checks/lib/stump-catalog.nix) { inherit pkgs; };
  inherit (stump) book;
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
            inherit opdsUser;
            # The catalog URL the provisioner hands the operator has to name the EDGE, which in
            # this test is `library.example.com` rather than the fleet's real domain. Overriding
            # it here is also what lets the OPDS walk below follow the minted URL literally,
            # instead of reassembling one and hoping the two agree.
            publicUrl = "https://${vhost}";
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
          systemd.tmpfiles.rules = [
            "d ${libraryPath} 2770 git-annex library -"
          ];

          # Satisfy the sops assertions without a real key/file, and force the four credential
          # secrets to plain files (same bypass as the #92 supernote test).
          sops.age.keyFile = "/etc/dummy-sops-key";
          sops.defaultSopsFile = pkgs.writeText "dummy-sops.yaml" "";
          sops.validateSopsFiles = false;
          sops.secrets."stump/user".path = lib.mkForce "/etc/mock-stump-user";
          sops.secrets."stump/password".path = lib.mkForce "/etc/mock-stump-password";
          sops.secrets."stump/opds_password".path = lib.mkForce "/etc/mock-stump-opds-password";
          environment.etc."mock-stump-user".text = owner;
          environment.etc."mock-stump-password".text = password;
          environment.etc."mock-stump-opds-password".text = opdsPassword;

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
    import shlex
    import time
    import xml.etree.ElementTree as ET

    # OPDS 1.2 is Atom; every element the walk below looks for is in the Atom namespace.
    ATOM = "{http://www.w3.org/2005/Atom}"

    PORT = ${toString port}
    LOCAL = f"http://127.0.0.1:{PORT}"

    BOOKS = "${libraryPath}/books"
    PAPERS = "${libraryPath}/papers"
    NOTEBOOKS = "${libraryPath}/notebooks"
    ORIGINALS = "${libraryPath}/_originals"


    def plant(directory, series, name, source):
        """Drop a book into `<root>/<series>/` — series-priority means a root's subdirectories are
        its series, the shape the corpus is curated in. Series dir 2770 and file 0640, both
        git-annex:library, so the ONLY way `stump` can read either is the group membership.
        Paths are shell-quoted: real series names have spaces in them."""
        series_dir = shlex.quote(f"{directory}/{series}")
        target = shlex.quote(f"{directory}/{series}/{name}.pdf")
        origin.succeed(f"install -d -o git-annex -g library -m 2770 {series_dir}")
        origin.succeed(f"install -m 0640 -o git-annex -g library {source} {target}")


    ${stump.helpers {
      node = "origin";
      inherit owner password port;
    }}


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

    # 4. THE GROUP READ PATH. First the mechanism, directly: a transient unit with the SAME
    #    identity and the same `PrivateUsers` sandbox the real service runs under. It reports the
    #    namespace's view of its groups (where the unmapped `library` gid shows as the overflow id,
    #    which is what makes this look broken) and then actually reads a corpus file. READ-OK is
    #    the finding: the name is squashed, the credential is not.
    #    The path goes in through --setenv rather than the command line, so the shell snippet stays
    #    free of nested quoting (real series names have spaces in them); `id` and `cat` are absolute
    #    because a transient unit inherits no PATH.
    probe = origin.succeed(
        "systemd-run --quiet --pipe --wait -p User=stump -p PrivateUsers=yes "
        f"--setenv=BOOK={shlex.quote(BOOKS + '/Stewart Brand/clocks-of-the-long-now.pdf')} "
        + """/bin/sh -c '/run/current-system/sw/bin/id -G; """
        + """/run/current-system/sw/bin/cat "$BOOK" >/dev/null && echo READ-OK'"""
    )
    assert "READ-OK" in probe, f"the stump user cannot read the corpus under PrivateUsers: {probe}"
    print(f"PrivateUsers sandbox: groups as seen inside the namespace + corpus read => {probe!r}")

    #    Then the thing that actually matters: the planted books are catalog entries, in the right
    #    library — which the real scanner, in the real unit, could only manage by reading a 2770
    #    tree it reaches solely through the `library` group.
    libraries = wait_for_catalog(
        lambda c: c["Books"]["books"] and c["Papers"]["books"],
        "the initial scan indexes the planted books",
    )
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

    # 6. THROUGH THE EDGE. In the deployment, kelpy reaches rk1b over `tailscale0` — which is
    #    precisely the interface the profile opens the port on, so the edge is inside the allow-list
    #    and everything else is outside it. This VM LAN has no tailnet, so subtest 5's rule blocks
    #    the edge too. Stand in for the tailnet by granting the EDGE, and only the edge, the same
    #    reach: a source-scoped accept ahead of the firewall's default drop. The `client.fail`
    #    re-asserted below is what keeps this honest — the exception is one host, not the LAN.
    edge_ip = edge.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()
    edge_ip6 = edge.succeed(
        "ip -6 -o addr show eth1 scope global | awk '{print $4}' | cut -d/ -f1"
    ).strip()
    origin.succeed(f"iptables -I nixos-fw 1 -s {edge_ip} -p tcp --dport {PORT} -j nixos-fw-accept")
    origin.succeed(f"ip6tables -I nixos-fw 1 -s {edge_ip6} -p tcp --dport {PORT} -j nixos-fw-accept")
    client.fail(f"curl -s -o /dev/null --max-time 8 http://origin:{PORT}/api/v2/ping")

    #    Caddy's `tls internal` CA is not in the client's trust store, hence -k; what matters is
    #    that the request arrives with the edge's Host + X-Forwarded-Proto, exactly as through kelpy.
    edge.wait_for_unit("caddy.service")
    edge.wait_for_open_port(443)
    resolve = f"--resolve ${vhost}:443:{edge_ip}"
    client.wait_until_succeeds(
        f"curl -skf {resolve} -o /dev/null https://${vhost}/api/v2/ping", timeout=90
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
    assert "https://${vhost}/" in feed, f"OPDS feed has no https://${vhost} self-links:\n{feed}"
    assert "http://${vhost}" not in feed, f"OPDS self-links use a non-TLS scheme:\n{feed}"
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
    wait_for_catalog(
        lambda c: c["Notebooks"]["books"] == ["2026-08-13"],
        "the watcher indexes a notebook dropped after the initial scan",
    )

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

    # ── 9. THE OPDS CATALOG CREDENTIAL (#114) ────────────────────────────────────────────────
    # The credential is declared, not minted: the username is a module option and the password is
    # a sops secret, so there is no handoff file, nothing for the operator to bank, and nothing
    # that could differ between the first deploy and the tenth. What the provisioner does is
    # converge the account and verify it — so what this section asserts is the verification.
    journal = origin.succeed("journalctl -u stump-provision --no-pager -o cat")
    assert "serves '${opdsUser}' over Basic auth" in journal, f"the credential was not verified:\n{journal}"
    assert "${opdsPassword}" not in journal, "the provisioner leaked the OPDS password into the journal"

    # No state is kept between runs. The old design left two 0600 files in the cache dir; their
    # absence is what proves the mint/bank machinery is gone rather than merely unused.
    origin.fail("test -e /var/cache/stump/opds-key")
    origin.fail("test -e /var/cache/stump/opds-url")

    # THE SCOPE, AS THE SERVER RESOLVES IT. The assertion that separates a scoped credential from
    # one that merely records a scope: `enforce_permissions` short-circuits on `is_server_owner`,
    # so had the device been pointed at the owner account it would pass every catalog request
    # below while holding full administrative rights.
    reader_jar = "/tmp/reader-jar"
    origin.succeed(
        f"curl -sf -c {reader_jar} -X POST {LOCAL}/api/v2/auth/login "
        "-H 'Content-Type: application/json' "
        f"""-d '{json.dumps({"username": "${opdsUser}", "password": "${opdsPassword}"})}' -o /dev/null"""
    )
    viewer = json.loads(origin.succeed(f"curl -sf -b {reader_jar} {LOCAL}/api/v2/auth/me"))
    assert viewer["username"] == "${opdsUser}", f"the credential belongs to {viewer['username']}"
    assert viewer["isServerOwner"] is False, "the OPDS account is the server owner"
    assert viewer["permissions"] == ["DOWNLOAD_FILE"], f"scope is {viewer['permissions']}"

    # BASIC AUTH IS CONFINED TO OPDS. This is what makes a password safe to type into a reader
    # app: `auth_middleware` gates the `Basic ` branch on `is_opds`, so the same credential that
    # opens the catalog cannot be replayed against the API. Asserted, not assumed — if a future
    # version widened it, the device's password would silently become an API credential.
    origin.fail(f"curl -sf -u ${opdsUser}:${opdsPassword} -o /dev/null {LOCAL}/api/v2/auth/me")

    # ── 10. THE DEVICE'S PATH, END TO END (#114/#115) ────────────────────────────────────────
    # From here on the test behaves like the reader app #115 will run: everything goes through the
    # edge over TLS, authenticated the way the device will authenticate, following links the feed
    # itself advertises rather than URLs assembled here.
    AUTH = "-u ${opdsUser}:${opdsPassword}"

    # An unauthenticated OPDS 1.2 request must be challenged, not served — and the challenge is
    # what tells a reader app to prompt for credentials, so its presence is part of the contract.
    challenge = client.succeed(
        f"curl -sk {resolve} -o /dev/null -D - https://${vhost}/opds/v1.2/catalog"
    )
    assert "401" in challenge.splitlines()[0], f"an unauthenticated catalog was served:\n{challenge}"
    # Case-insensitively: the edge speaks HTTP/2, which lowercases header names on the wire, so
    # the `WWW-Authenticate` Stump writes arrives as `www-authenticate`. A reader app parsing the
    # challenge sees the same thing, which is the reason to assert it through the edge and not
    # against the origin.
    assert "www-authenticate: basic" in challenge.lower(), f"no Basic auth challenge:\n{challenge}"

    # A wrong password is refused. Without this the assertions below would pass against a server
    # that had stopped checking credentials at all.
    client.fail(f"curl -skf {resolve} -u ${opdsUser}:wrong-password -o /dev/null https://${vhost}/opds/v1.2/catalog")

    def opds(path):
        return client.succeed(f"curl -skf {resolve} {AUTH} 'https://${vhost}{path}'")

    def entries(document):
        # findall, NOT iter: `iter` recurses, so it would also collect entries nested inside
        # another entry and flatten the navigation hierarchy this walk is meant to descend.
        return {e.findtext(ATOM + "title"): e for e in ET.fromstring(document).findall(ATOM + "entry")}

    def follow(entry, rel):
        # Raises rather than returning None: a missing link is a broken catalog, and continuing
        # with None would fail later somewhere less informative.
        for candidate in entry.findall(ATOM + "link"):
            if candidate.get("rel") == rel:
                return candidate.get("href")
        raise Exception(f"no {rel} link on entry {entry.findtext(ATOM + 'title')!r}")

    # The root is a NAVIGATION feed — 'All books', 'All series', 'Keep reading' and so on — so the
    # libraries hang off 'All libraries' rather than appearing at the top level.
    root = entries(opds("/opds/v1.2/catalog"))
    assert "All libraries" in root, f"the catalog has no library navigation: {sorted(root)}"
    libraries_feed = entries(opds(follow(root["All libraries"], "subsection")))
    assert set(libraries_feed) == {"Books", "Papers", "Notebooks"}, sorted(libraries_feed)

    series_feed = entries(opds(follow(libraries_feed["Books"], "subsection")))
    assert "Stewart Brand" in series_feed, f"Books has no Stewart Brand series: {sorted(series_feed)}"

    books_feed = entries(opds(follow(series_feed["Stewart Brand"], "subsection")))
    assert len(books_feed) == 1, f"expected one book in the series: {sorted(books_feed)}"
    acquisition = follow(next(iter(books_feed.values())), "http://opds-spec.org/acquisition")

    # THE BYTES. The acquisition link yields exactly what was planted — compared by digest, so a
    # truncated or re-encoded download cannot pass. This is the closest a VM can get to "a reader
    # app downloaded the book"; an actual client on the actual device is palimpsest#115.
    client.succeed(f"curl -skf {resolve} {AUTH} -o /tmp/acquired.pdf 'https://${vhost}{acquisition}'")
    downloaded = client.succeed("sha256sum /tmp/acquired.pdf").split()[0]
    planted = origin.succeed(
        f"sha256sum {shlex.quote(BOOKS + '/Stewart Brand/clocks-of-the-long-now.pdf')}"
    ).split()[0]
    assert downloaded == planted, f"downloaded {downloaded}, planted {planted}"

    # The acquisition link is credentialled too, not just the catalog entry point — otherwise the
    # books would be readable by anyone who could guess a media id.
    client.fail(f"curl -skf {resolve} -o /dev/null 'https://${vhost}{acquisition}'")
  '';
}
