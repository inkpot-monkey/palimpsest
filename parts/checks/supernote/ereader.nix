# Acceptance test for the ereader downward mirror (ADR-0031, palimpsest#107 as reduced by #117).
#
# Drives the mirror end-to-end against the REAL packaged server + reconciler, over a REAL git-annex
# `library` tree, with the REAL Stump catalog running on that same tree — the one-node integration
# originally scoped as palimpsest#95, narrowed to what now exists. A `client` node stands in for the
# Nomad: it opens sync sessions (the reconcile's only trigger) and, acting as the device's 2-way
# sync, adds and deletes documents in the store through the client API. There is no upload path to
# test any more; #117 removed it, along with the outbox and the last-synced baseline.
#
#   A. MATERIALISATION. The device puts a PDF in the store's ereader folder and syncs → the
#      reconcile fires off that sync and materialises it into library/ereader/ as a REAL file
#      (content-identical, not a symlink to nowhere and not an opaque blob), inside the git-annex
#      tree, which then adopts it. Real files are the point: git-annex replicates content and Stump
#      indexes files, neither of which can be done with the store's UUID blobs.
#   B. IDEMPOTENCE across restart. Restart the server, reconcile again → downloaded=0 deleted=0.
#      With the baseline gone this is no longer a claim about persisted state; it is the claim that
#      the mirror derives entirely from the store, so a restart changes nothing.
#   C. DURABLE DELETE. The device deletes the document from the store; reconcile → it leaves
#      library/ereader/ and is NOT resurrected by the next reconcile (nothing can push it back).
#      It is deliberately the device's LAST document, so the store's listing goes empty and the
#      delete must still propagate — see D for why that distinction is the whole ballgame.
#   D. A LOST STORE. A genuinely WIPED store — not merely an empty one — leaves a file sitting in
#      library/ereader/ untouched. The guard keys on the remote ereader folder being absent, not on
#      an empty listing, because C proves an empty listing is a legitimate state of a live store;
#      conflating them would swallow the last delete permanently. Wiped for real here, and the
#      bootstrap's register path is asserted as proof it was.
#   E. UNREACHABLE STORE. With the server stopped, the reconcile FAILS (loudly, as a failed unit)
#      and deletes nothing — login happens before any library mutation, so there is no path from
#      "the store is not answering" to "the backup is smaller".
#   F. THE CATALOG COEXISTS, AND THE MIRROR STAYS OUT OF IT. Stump indexes books/, papers/ and
#      notebooks/; `ereader/` is a sibling of all three, so handwriting coming back from the device
#      does not surface as a second copy of a book the catalog already serves. That placement is
#      what makes it true — no ignore glob — and full-corpus classification into the three roots is
#      explicitly future work in ADR-0031, so this pins today's shape rather than a permanent one.
#
# sops is bypassed exactly as parts/checks/supernote/default.nix does: dummy age key + forced
# secret paths pointing at plain /etc files, so no real decryption happens in the sandbox.
{
  self,
  pkgs,
  inputs,
}:
let
  # The account the server bootstraps from the mock credential (must be a valid email — the server
  # validates EMAIL_REGEX on register). Reused verbatim by the client-side device driver.
  account = "device@example.com";
  password = "sync-secret-123";

  # The Stump owner account its provisioner claims, plus the non-owner OPDS account it creates.
  # Neither is exercised as a credential here (palimpsest#113's check does that); they exist because
  # the catalog cannot start without them.
  stumpOwner = "reader";
  stumpPassword = "catalog-secret-123";
  stumpOpdsUser = "opds";
  stumpOpdsPassword = "opds-secret-456";

  # rk1b's tree lives on the NVMe /var/cache subtree; there is no such mount here, but the path is
  # kept so the git-annex repository, the mirror and the Stump roots sit in the same relationship.
  libraryPath = "/var/cache/library";

  inherit (self.settings.services.private.library) port;

  # The shared git-annex test scaffolding (mesh SSH trust at boot), so the tree under the mirror is
  # a REAL annex repository rather than a plain directory wearing its ownership.
  gitAnnex = import (self + /modules/nixos/services/git-annex/tests/lib.nix) { inherit pkgs; };

  # A python interpreter with the `supernote` library importable — the same construction the
  # profile uses for the reconciler (toPythonModule re-exposes the application's modules). Drives
  # the device APIs (sync_start, list_folder, upload_content, delete_by_path) from the client, as a
  # real device would.
  snpy = pkgs.python313.withPackages (ps: [ (ps.toPythonModule pkgs.supernote) ]);

  # A real PDF, not a stub. Content type is the whole point of subtest F: Stump dispatches on it and
  # only handles zip/rar/epub/pdf, so a text file left out of the catalog would prove nothing about
  # placement. `groff.perl` carries `gropdf`, which nixpkgs splits out of the main `groff` output.
  document =
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

  # What the device "wrote on" and syncs back — an annotated PDF is the realistic shape of what the
  # Private Cloud carries now that books go out over OPDS.
  annotated = document "field-notes" "A document the device annotated and synced back.";
  # A book in a Stump root, so subtest F's negative assertion has a positive control: the same file
  # type IS indexed when it sits in an indexed root.
  shelved = document "clocks-of-the-long-now" "A book in the Books root.";

  # A tiny device driver: `sync` opens a sync session (the reconcile's only trigger); `ls` prints
  # the ereader folder listing as `<path_display>\t<content_hash>` lines; `put <local> <remote>`
  # uploads a document as the device's own sync would; `rm <path>` deletes one.
  #
  # It CACHES its access token to a file and reuses it, re-logging-in only when the token is
  # missing or rejected. That is what a real Nomad does — it authenticates once at pairing and then
  # carries a long-lived JWT (which is exactly why the profile persists a stable JWT signing key
  # across restarts). It also matters for correctness of this test: the driver is invoked by
  # `wait_until_succeeds`, which re-runs it every second, so logging in per invocation would
  # manufacture a login storm no device produces — and upstream keeps only ONE login challenge per
  # account (`challenge:{account}`, palimpsest#142), so a storm makes concurrent logins fail with a
  # misleading 401. Caching keeps the polling honest and tests the sync, not the login endpoint.
  driver = pkgs.writeText "sn-ereader-driver.py" ''
    import asyncio
    import os
    import sys
    from pathlib import Path

    from supernote.client import Supernote
    from supernote.client.exceptions import NotFoundException, UnauthorizedException

    URL = os.environ["URL"]
    USER = os.environ["SN_USER"]
    PW = os.environ["SN_PASS"]
    TOKEN_FILE = Path(os.environ.get("SN_TOKEN_FILE", "/tmp/sn-device-token"))
    REMOTE_DIR = "/DOCUMENT/Document/ereader"


    def cached_token():
        if TOKEN_FILE.is_file():
            return TOKEN_FILE.read_text().strip() or None
        return None


    async def fresh_login():
        sn = await Supernote.login(USER, PW, host=URL)
        if sn.token:
            TOKEN_FILE.write_text(sn.token)
        return sn


    async def act(sn, cmd):
        if cmd == "sync":
            await sn.device.sync_start("TEST-DEVICE")
            print("sync started")
        elif cmd == "ls":
            try:
                listing = await sn.device.list_folder(REMOTE_DIR, recursive=True)
            except NotFoundException:
                return
            for e in listing.entries:
                print(f"{e.path_display}\t{e.content_hash}")
        elif cmd == "put":
            local, name = sys.argv[2], sys.argv[3]
            await sn.device.upload_content(f"{REMOTE_DIR}/{name}", Path(local).read_bytes())
            print("uploaded")
        elif cmd == "rm":
            await sn.device.delete_by_path(sys.argv[2])
            print("deleted")


    async def main():
        cmd = sys.argv[1]
        # Try the cached token first; fall back to a real login only if it is missing or the
        # server rejects it. No extra probe request — the command itself is the probe.
        token = cached_token()
        if token:
            try:
                async with Supernote.from_token(token, host=URL) as sn:
                    await act(sn, cmd)
                    return
            except UnauthorizedException:
                pass
        async with await fresh_login() as sn:
            await act(sn, cmd)


    asyncio.run(main())
  '';

  env = "URL=http://server:8080 SN_USER=${account} SN_PASS=${password}";
in
pkgs.testers.nixosTest {
  name = "supernote-ereader-mirror-test";

  nodes = {
    server =
      { lib, ... }:
      {
        imports = [
          inputs.sops-nix.nixosModules.sops
          inputs.impermanence.nixosModules.impermanence
          gitAnnex.commonNode
          (self + /modules/nixos/profiles/supernote.nix)
          (self + /modules/nixos/profiles/stump.nix)
        ];

        options.custom.profiles.impermanence.enable = lib.mkEnableOption "impermanence (test stub)";

        config = {
          # Both profiles read `self.lib.getSecretFile`; Stump also takes its port and public URL
          # from the service registry. Test nodes get neither module arg from specialArgs.
          _module.args.self = self;
          _module.args.settings = self.settings;

          custom.profiles.supernote.enable = true;
          # The feature under test.
          custom.profiles.supernote.ereader = {
            enable = true;
            inherit libraryPath;
          };

          # The catalog over the same tree — the coexistence half of the integration (subtest F).
          custom.profiles.stump = {
            enable = true;
            inherit libraryPath;
            opdsUser = stumpOpdsUser;
            publicUrl = "https://library.example.com";
          };

          # The tree itself: a REAL git-annex repository, wired exactly as hosts/rk1/library.nix
          # wires it — git-annex owns it, the pinned-GID `library` group is the sharing seam, 2770
          # setgid, unlock + thin so the working tree holds real files (which is what the mirror
          # writes and what Stump reads), assistant on so the annex adopts them autonomously. No
          # remote is declared: replication rk1b <-> kelpy is proven by the git-annex-library test,
          # and a second node here would only add contention.
          users.groups.library.gid = 977;
          services.git-annex.repositories.library = {
            path = libraryPath;
            description = "rk1b-library";
            ownerGroup = "library";
            mode = "2770";
            unlock = true;
            thin = true;
            assistant = true;
            group = "backup";
            wanted = "standard";
          };
          users.users.git-annex.extraGroups = [ "library" ];

          # Satisfy the sops assertions without a real key/file, and force every credential to a
          # plain file (same bypass as the #92 server test).
          sops.age.keyFile = "/etc/dummy-sops-key";
          sops.defaultSopsFile = pkgs.writeText "dummy-sops.yaml" "";
          sops.validateSopsFiles = false;
          sops.secrets."supernote/user".path = lib.mkForce "/etc/mock-supernote-user";
          sops.secrets."supernote/password".path = lib.mkForce "/etc/mock-supernote-password";
          sops.secrets."stump/user".path = lib.mkForce "/etc/mock-stump-user";
          sops.secrets."stump/password".path = lib.mkForce "/etc/mock-stump-password";
          sops.secrets."stump/opds_password".path = lib.mkForce "/etc/mock-stump-opds-password";
          environment.etc."mock-supernote-user".text = account;
          environment.etc."mock-supernote-password".text = password;
          environment.etc."mock-stump-user".text = stumpOwner;
          environment.etc."mock-stump-password".text = stumpPassword;
          environment.etc."mock-stump-opds-password".text = stumpOpdsPassword;

          environment.systemPackages = [ pkgs.curl ];
          # Two servers, an annex assistant, and Stump's first-scan PDF thumbnailing.
          virtualisation.memorySize = 3072;
        };
      };

    client = {
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  testScript = ''
    import json
    import shlex
    import time

    LOCAL_STUMP = "http://127.0.0.1:${toString port}"
    MIRROR = "${libraryPath}/ereader"


    def reconcile_summary():
        # The newest `downloaded=.. deleted=..` summary line from the reconcile unit.
        log = server.succeed("journalctl -u supernote-ereader-reconcile --no-pager -o cat")
        lines = [ln for ln in log.splitlines() if "ereader reconcile: downloaded=" in ln]
        assert lines, f"no reconcile summary line found:\n{log}"
        return lines[-1]


    def reconcile(expected):
        # A direct start is a faithful re-run of what the watcher triggers, and sidesteps its
        # debounce window. `systemctl start` on a oneshot blocks until it finishes.
        server.systemctl("start supernote-ereader-reconcile.service")
        summary = reconcile_summary()
        assert expected in summary, f"expected '{expected}', got:\n{summary}"


    def graphql(query):
        """Run a query as the Stump owner; the REST login's cookie authorises GraphQL."""
        server.succeed(
            f"curl -sf -c /tmp/jar -X POST {LOCAL_STUMP}/api/v2/auth/login "
            "-H 'Content-Type: application/json' "
            f"""-d '{json.dumps({"username": "${stumpOwner}", "password": "${stumpPassword}"})}' -o /dev/null"""
        )
        body = json.dumps({"query": query})
        raw = server.succeed(
            f"curl -sf -b /tmp/jar -X POST {LOCAL_STUMP}/api/graphql "
            f"-H 'Content-Type: application/json' -d {shlex.quote(body)}"
        )
        parsed = json.loads(raw)
        assert "errors" not in parsed, f"GraphQL errors: {parsed}"
        return parsed["data"]


    def catalog():
        """{library name: sorted media names} straight from the server."""
        data = graphql("{ libraries { nodes { name media { name } } } }")
        return {
            node["name"]: sorted(m["name"] for m in node["media"])
            for node in data["libraries"]["nodes"]
        }


    def wait_for_catalog(predicate, what, tries=60):
        """A scan is a background job kicked off by library creation, so `stump-provision` going
        active does not mean the books are indexed yet."""
        with server.nested(f"waiting for the catalog: {what}"):
            for _ in range(tries):
                snapshot = catalog()
                if predicate(snapshot):
                    return snapshot
                time.sleep(3)
        raise Exception(f"catalog never reached '{what}': {catalog()}")


    start_all()

    # The tree, the server, its account, the mirror folder and the sync watcher all come up.
    server.wait_for_unit("git-annex-init-library.service")
    server.wait_for_unit("supernote-server.service")
    server.wait_for_open_port(8080)
    server.wait_for_unit("supernote-account-bootstrap.service")
    server.wait_for_unit("supernote-ereader-dir.service")
    server.wait_for_unit("supernote-ereader-watch.service")

    # library/ereader/ exists, group `library`, setgid (2770), owned by the tree owner git-annex —
    # the "stays git-annex-owned, group-readable" acceptance criterion, asserted against the real
    # annex repo rather than a stand-in directory.
    perms = server.succeed(f"stat -c '%a %U %G' {MIRROR}").strip()
    assert perms == "2770 git-annex library", f"unexpected mirror dir perms: {perms}"
    # And the retired one-shot outbox is NOT created — #117 removed it, and the sweep in the same
    # oneshot removes any left by an earlier deploy. It sits inside the BACKED-UP tree, so an
    # abandoned directory would be replicated and carried offsite forever.
    server.succeed("test ! -e ${libraryPath}/ereader-outbox")
    # Nor is there any persisted reconcile state left in the server store.
    server.succeed("test ! -e /var/lib/supernote/reconcile")

    client.wait_until_succeeds("curl -sf -o /dev/null http://server:8080/api/csrf", timeout=60)

    # ── A. MATERIALISATION ──────────────────────────────────────────────────────────────────────
    # The device puts an annotated document in its ereader folder and opens a sync — the reconcile's
    # ONLY trigger. Nothing on the server side put it there; there is no longer a way to.
    client.succeed("${env} ${snpy}/bin/python ${driver} put ${annotated} field-notes.pdf")
    client.succeed("${env} ${snpy}/bin/python ${driver} sync")

    # It materialises down into library/ereader/, fired by that sync.
    server.wait_until_succeeds(f"test -f {MIRROR}/field-notes.pdf", timeout=90)
    # A REAL file with the device's exact bytes — not a blob, not a dangling annex symlink. `-L`
    # would follow a symlink, so check both: identical content AND a resolvable, non-empty file.
    server.succeed(f"cmp ${annotated} {MIRROR}/field-notes.pdf")
    server.succeed(f"test -s {MIRROR}/field-notes.pdf")

    # The trigger really was the sync, and the reconcile downloaded exactly the one document.
    watch_log = server.succeed("journalctl -u supernote-ereader-watch --no-pager -o cat")
    assert "device sync detected" in watch_log, f"watcher never saw the sync:\n{watch_log}"
    assert "downloaded=1 deleted=0" in reconcile_summary(), (
        f"the mirror did not materialise the one document:\n{reconcile_summary()}"
    )

    # git-annex adopts what the mirror wrote, autonomously — no manual command. This is what makes
    # the tree replicated and backed up rather than merely owned by git-annex.
    server.wait_until_succeeds(
        "sudo -u git-annex -H env HOME=/var/lib/git-annex "
        "git -C ${libraryPath} annex whereis ereader/field-notes.pdf",
        timeout=120,
    )

    # ── B. IDEMPOTENCE across restart ───────────────────────────────────────────────────────────
    # The mirror derives entirely from the store, so restarting the server changes nothing: no
    # re-download (content matches) and no delete (the document is still in the store).
    server.systemctl("restart supernote-server.service")
    server.wait_for_open_port(8080)
    reconcile("downloaded=0 deleted=0")
    server.succeed(f"test -f {MIRROR}/field-notes.pdf")

    # ── F. THE CATALOG COEXISTS, AND THE MIRROR STAYS OUT OF IT ─────────────────────────────────
    # Stump is up on the same tree, reaching it through the `library` group. A book planted in the
    # Books root IS indexed; the document the device synced back is the same file type but sits in
    # `ereader/`, a sibling of all three roots, so it is not — placement is what does that, and it
    # is why handwriting returning from the device cannot appear as a second copy of a book the
    # catalog already serves. (Classifying the mirror into books/papers/notebooks is explicitly
    # future work in ADR-0031; when that lands, this expectation is what should be revisited.)
    server.wait_for_unit("stump-library-roots.service")
    server.wait_for_unit("stump.service")
    server.wait_for_open_port(${toString port})
    server.wait_for_unit("stump-provision.service")
    server.succeed(
        "install -d -o git-annex -g library -m 2770 ${libraryPath}/books/'Stewart Brand'"
    )
    server.succeed(
        "install -m 0640 -o git-annex -g library ${shelved} "
        "${libraryPath}/books/'Stewart Brand'/clocks-of-the-long-now.pdf"
    )
    indexed = wait_for_catalog(
        lambda c: c.get("Books") == ["clocks-of-the-long-now"],
        "the planted book is indexed",
    )
    everything = [name for names in indexed.values() for name in names]
    assert "field-notes" not in everything, (
        f"the ereader mirror leaked into the catalog: {indexed}"
    )

    # ── C. DURABLE DELETE ───────────────────────────────────────────────────────────────────────
    # The device deletes the document from the store (its 2-way sync propagating a device-side
    # delete). With no upload path there is no ambiguity left to resolve and no baseline to consult:
    # absent from the store means gone.
    #
    # This is the device's ONLY document, so the store's listing is empty immediately afterwards.
    # That is deliberate: it is the case a naive "empty store means the store is lost" guard gets
    # wrong, and it would get it wrong PERMANENTLY, because after the fact nothing distinguishes
    # "the device emptied its folder" from "the store was wiped". The delete must propagate here.
    client.succeed("${env} ${snpy}/bin/python ${driver} rm /DOCUMENT/Document/ereader/field-notes.pdf")
    reconcile("downloaded=0 deleted=1")
    server.succeed(f"test ! -e {MIRROR}/field-notes.pdf")

    # ...and it is NOT resurrected: nothing can push it back, so a second reconcile is a no-op and
    # the store stays empty.
    reconcile("downloaded=0 deleted=0")
    server.succeed(f"test ! -e {MIRROR}/field-notes.pdf")
    listing = client.succeed("${env} ${snpy}/bin/python ${driver} ls")
    assert "field-notes.pdf" not in listing, f"the deleted document came back in the store:\n{listing}"

    # ── D. A LOST STORE ─────────────────────────────────────────────────────────────────────────
    # Note what subtest C just established: the device's LAST document was deleted, so the store's
    # listing went empty, and the delete still propagated. Emptiness is therefore not the loss
    # signal — it cannot be, or that delete would have been swallowed and nothing afterwards could
    # ever tell the two apart. The signal is the remote ereader folder being ABSENT, which is what a
    # wiped or not-yet-re-seeded store looks like (the store is rebuildable and deliberately
    # un-backed-up, ADR-0031). So wipe the store for real rather than merely emptying it.
    #
    # The watcher is stopped first on purpose: it fires the reconcile, which `Requires=` the server,
    # so a sync line arriving mid-wipe would start the server back up underneath us.
    server.systemctl("stop supernote-ereader-watch.service")
    server.systemctl("stop supernote-account-bootstrap.service")
    server.systemctl("stop supernote-server.service")
    server.succeed("find /var/lib/supernote -mindepth 1 -maxdepth 1 -exec rm -rf {} +")
    server.systemctl("start supernote-server.service")
    server.wait_for_open_port(8080)
    server.systemctl("restart supernote-account-bootstrap.service")
    server.wait_for_unit("supernote-account-bootstrap.service")
    # Proof the store really was wiped and not just restarted: the bootstrap took its REGISTER path,
    # which is reachable only on an empty database.
    bootstrap = server.succeed("journalctl -u supernote-account-bootstrap --no-pager -o cat")
    assert "no account yet" in bootstrap, (
        f"the store was not actually wiped — bootstrap took the idempotent path:\n{bootstrap}"
    )

    # A file in the mirror must survive that. This is the whole point of the guard: the tree is the
    # backed-up one and the store is not.
    server.succeed(f"echo -n 'precious-backup' > {MIRROR}/orphan.txt")
    server.succeed(f"chown git-annex:library {MIRROR}/orphan.txt")
    reconcile("downloaded=0 deleted=0")
    server.succeed(f"test -f {MIRROR}/orphan.txt")
    body = server.succeed(f"cat {MIRROR}/orphan.txt")
    assert body == "precious-backup", f"the guarded file was clobbered: {body!r}"
    guard_log = server.succeed("journalctl -u supernote-ereader-reconcile --no-pager -o cat")
    assert "no /DOCUMENT/Document/ereader in the store" in guard_log, (
        f"the missing folder was not reported as the reason nothing was deleted:\n{guard_log}"
    )
    server.systemctl("start supernote-ereader-watch.service")

    # ── E. UNREACHABLE STORE ────────────────────────────────────────────────────────────────────
    # Point the reconciler at a dead port rather than stopping the server: the reconcile unit
    # Requires= supernote-server, so `systemctl start` on it would pull the server straight back up
    # and there would be nothing unreachable about the store. A refused connection at the URL is the
    # same thing from the reconciler's side, and it isolates the behaviour under test from systemd's
    # dependency handling. A runtime drop-in, so it evaporates with /run.
    server.succeed(
        "mkdir -p /run/systemd/system/supernote-ereader-reconcile.service.d && "
        "printf '[Service]\nEnvironment=SUPERNOTE_URL=http://127.0.0.1:9\n' "
        "> /run/systemd/system/supernote-ereader-reconcile.service.d/unreachable.conf && "
        "systemctl daemon-reload"
    )
    # It must FAIL — a broken reconcile is a failed unit, not a silent no-op — and must not have
    # touched the tree, because login happens before any library mutation.
    server.fail("systemctl start supernote-ereader-reconcile.service")
    server.succeed(f"test -f {MIRROR}/orphan.txt")
    failure = server.succeed("journalctl -u supernote-ereader-reconcile --no-pager -o cat")
    assert "ereader reconcile: FAILED" in failure, (
        f"an unreachable store did not fail the unit loudly:\n{failure}"
    )
  '';
}
