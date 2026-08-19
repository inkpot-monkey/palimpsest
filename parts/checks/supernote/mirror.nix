# Acceptance test for the Supernote downward mirror (ADR-0031, palimpsest#107 as reduced by #117).
#
# Drives the mirror end-to-end against the REAL packaged server + mirror unit, over a REAL git-annex
# `library` tree, with the REAL Stump catalog running on that same tree — the one-node integration
# originally scoped as palimpsest#95, narrowed to what now exists. A `client` node stands in for the
# Nomad: it opens sync sessions (the mirror's only trigger) and, acting as the device's 2-way
# sync, adds and deletes documents in the store through the client API. There is no upload path to
# test any more; #117 removed it, along with the outbox and the last-synced baseline.
#
#   A. MATERIALISATION. The device puts files in TWO different firmware folders (Document/ and
#      Note/) and syncs → the mirror fires off that sync and materialises both under
#      library/supernote/ at the device's own relative paths, as REAL files
#      (content-identical, not a symlink to nowhere and not an opaque blob), inside the git-annex
#      tree, which then adopts it. Real files are the point: git-annex replicates content and Stump
#      indexes files, neither of which can be done with the store's UUID blobs.
#   B. IDEMPOTENCE across restart. Restart the server, run again → downloaded=0 deleted=0.
#      With the baseline gone this is no longer a claim about persisted state; it is the claim that
#      the mirror derives entirely from the store, so a restart changes nothing.
#   C. DURABLE DELETE. The device deletes a document from the store; the mirror → it leaves the
#      tree and is NOT resurrected by the next run (nothing can push it back). Other content stays
#      in the store, so this is the everyday case the guard must not touch.
#   D. A LOST STORE. A genuinely WIPED store leaves a file sitting in the mirror untouched. At
#      whole-device scope an empty listing IS the loss signal — it means the device's entire VFS is
#      empty — which is why C can delete the last file in a folder without tripping it: the store
#      still lists the device's other content. Wiped for real here, and the bootstrap's register
#      path is asserted as proof it was.
#   E. UNREACHABLE STORE. Pointed at a dead port, the mirror FAILS (loudly, as a failed unit)
#      and deletes nothing — login happens before any library mutation, so there is no path from
#      "the store is not answering" to "the backup is smaller".
#   F. THE CATALOG COEXISTS, AND THE MIRROR STAYS OUT OF IT. Stump indexes books/, papers/ and
#      notebooks/; `supernote/` is a sibling of all three, so content coming back from the device
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

  # The Stump owner account its provisioner claims, plus the one reader it creates. Neither is
  # exercised as a credential here (palimpsest#113's check does that); they exist because the
  # catalog cannot finish provisioning without them.
  stumpOwner = "catalog-owner";
  stumpPassword = "catalog-secret-123";
  stumpReader = "thomas";
  stumpReaderPassword = "reader-secret-456";
  stumpReaderKey = "stump_9f3a1c7e_4b6d2a8f0e5c1937d84b2a6f0c7e315984d2b6a0";

  # rk1b's tree lives on the NVMe /var/cache subtree; there is no such mount here, but the path is
  # kept so the git-annex repository, the mirror and the Stump roots sit in the same relationship.
  libraryPath = "/var/cache/library";

  inherit (self.settings.services.private.library) port;

  # The shared git-annex test scaffolding (mesh SSH trust at boot), so the tree under the mirror is
  # a REAL annex repository rather than a plain directory wearing its ownership.
  gitAnnex = import (self + /modules/nixos/services/git-annex/tests/lib.nix) { inherit pkgs; };

  # A python interpreter with the `supernote` library importable — the same construction the
  # profile uses for the mirror (toPythonModule re-exposes the application's modules). Drives
  # the device APIs (sync_start, list_folder, upload_content, delete_by_path) from the client, as a
  # real device would.
  snpy = pkgs.python313.withPackages (ps: [ (ps.toPythonModule pkgs.supernote) ]);

  # The shared Stump scaffolding: a real PDF builder plus the catalog helpers. Extracted rather
  # than copied from parts/checks/stump — content type is the whole point of subtest F, since Stump
  # dispatches on it and a stub file would make the placement assertion vacuous.
  stump = import (self + /parts/checks/lib/stump-catalog.nix) { inherit pkgs; };
  inherit (stump) book;

  # What the device "wrote on" and syncs back — an annotated PDF is the realistic shape of what the
  # Private Cloud carries now that books go out over OPDS.
  annotated = book "field-notes" "A document the device annotated and synced back.";
  # A stand-in for a `.note` notebook. Its BYTES are arbitrary — nothing here parses the format —
  # but its PLACEMENT is the whole point: `/NOTE/Note` is where the firmware keeps handwriting, it
  # is the reason the Private Cloud server is still deployed at all, and the previous
  # `ereader/`-scoped mirror could never have seen it.
  scribble = pkgs.writeText "scribble.note" "SUPERNOTE-NOTE stand-in: the pen layer comes home.";
  # A book in a Stump root, so subtest F's negative assertion has a positive control: the same file
  # type IS indexed when it sits in an indexed root.
  shelved = book "clocks-of-the-long-now" "A book in the Books root.";

  # A tiny device driver: `sync` opens a sync session (the mirror's only trigger); `ls` prints the
  # WHOLE device listing as `<path_display>\t<content_hash>` lines; `put <local> <device-path>`
  # uploads a document as the device's own sync would; `rm <device-path>` deletes one.
  #
  # It CACHES its access token to a file and reuses it, re-logging-in only when the token is
  # missing or rejected. That is what a real Nomad does — it authenticates once at pairing and then
  # carries a long-lived JWT (which is exactly why the profile persists a stable JWT signing key
  # across restarts). It also matters for correctness of this test: the driver is invoked by
  # `wait_until_succeeds`, which re-runs it every second, so logging in per invocation would
  # manufacture a login storm no device produces — and upstream keeps only ONE login challenge per
  # account (`challenge:{account}`, palimpsest#142), so a storm makes concurrent logins fail with a
  # misleading 401. Caching keeps the polling honest and tests the sync, not the login endpoint.
  driver = pkgs.writeText "sn-device-driver.py" ''
    import asyncio
    import os
    import sys
    from pathlib import Path

    from supernote.client import Supernote
    from supernote.client.exceptions import UnauthorizedException

    URL = os.environ["URL"]
    USER = os.environ["SN_USER"]
    PW = os.environ["SN_PASS"]
    TOKEN_FILE = Path(os.environ.get("SN_TOKEN_FILE", "/tmp/sn-device-token"))


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
            listing = await sn.device.list_folder("/", recursive=True)
            for e in listing.entries:
                print(f"{e.path_display}\t{e.content_hash}")
        elif cmd == "put":
            local, remote = sys.argv[2], sys.argv[3]
            await sn.device.upload_content(remote, Path(local).read_bytes())
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
  name = "supernote-mirror-test";

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
          custom.profiles.supernote.mirror = {
            enable = true;
            inherit libraryPath;
          };

          # The catalog over the same tree — the coexistence half of the integration (subtest F).
          custom.profiles.stump = {
            enable = true;
            inherit libraryPath;
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

          # The readers map, as the WHOLE decrypted bundle — the profile takes `key = ""` and
          # `yq`s `.stump.readers` out of it. It MUST be present and well-formed even though this
          # check exercises no reader credential: `stump-provision` loads it as a systemd
          # credential, and LoadCredential= on a missing path fails the unit at step CREDENTIALS
          # before the script runs at all.
          sops.secrets.stump_readers_bundle.path = lib.mkForce "/etc/mock-stump-bundle";
          environment.etc."mock-supernote-user".text = account;
          environment.etc."mock-supernote-password".text = password;
          environment.etc."mock-stump-user".text = stumpOwner;
          environment.etc."mock-stump-password".text = stumpPassword;
          environment.etc."mock-stump-bundle".text = ''
            stump:
              readers:
                ${stumpReader}:
                  password: ${stumpReaderPassword}
                  koreader_key: ${stumpReaderKey}
          '';

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

    MIRROR = "${libraryPath}/supernote"


    def mirror_summary():
        # The newest `store=.. downloaded=.. deleted=..` summary line from the mirror unit.
        log = server.succeed("journalctl -u supernote-mirror --no-pager -o cat")
        lines = [ln for ln in log.splitlines() if "supernote mirror: store=" in ln]
        assert lines, f"no mirror summary line found:\n{log}"
        return lines[-1]


    def run_mirror(expected):
        # A direct start is a faithful re-run of what the watcher triggers, and sidesteps its
        # debounce window. `systemctl start` on a oneshot blocks until it finishes.
        server.systemctl("start supernote-mirror.service")
        summary = mirror_summary()
        assert expected in summary, f"expected '{expected}', got:\n{summary}"


    ${stump.helpers {
      node = "server";
      owner = stumpOwner;
      password = stumpPassword;
      inherit port;
    }}


    start_all()

    # The tree, the server, its account, the mirror folder and the sync watcher all come up.
    server.wait_for_unit("git-annex-init-library.service")
    server.wait_for_unit("supernote-server.service")
    server.wait_for_open_port(8080)
    server.wait_for_unit("supernote-account-bootstrap.service")
    server.wait_for_unit("supernote-mirror-dir.service")
    server.wait_for_unit("supernote-mirror-watch.service")

    # library/supernote/ exists, group `library`, setgid (2770), owned by the tree owner git-annex —
    # the "stays git-annex-owned, group-readable" acceptance criterion, asserted against the real
    # annex repo rather than a stand-in directory.
    perms = server.succeed(f"stat -c '%a %U %G' {MIRROR}").strip()
    assert perms == "2770 git-annex library", f"unexpected mirror dir perms: {perms}"
    # And the retired one-shot outbox is NOT created — #117 removed it, and the sweep in the same
    # oneshot removes any left by an earlier deploy. It sits inside the BACKED-UP tree, so an
    # abandoned directory would be replicated and carried offsite forever.
    for retired in ["ereader-outbox", "ereader"]:
        server.succeed("test ! -e ${libraryPath}/" + retired)
    # Nor is there any persisted mirror state left in the server store.
    server.succeed("test ! -e /var/lib/supernote/reconcile")

    client.wait_until_succeeds("curl -sf -o /dev/null http://server:8080/api/csrf", timeout=60)

    # ── A. MATERIALISATION, ACROSS THE WHOLE DEVICE ─────────────────────────────────────────────
    # The device puts content in TWO different firmware folders and opens a sync — the mirror's ONLY
    # trigger. Nothing on the server side put either there; there is no longer a way to. Two folders
    # rather than one is the point of this ticket: mirroring a single chosen folder is what missed
    # the handwriting entirely, so the test drives the doc root AND the note root.
    client.succeed(
        "${env} ${snpy}/bin/python ${driver} put ${annotated} /DOCUMENT/Document/field-notes.pdf"
    )
    client.succeed(
        "${env} ${snpy}/bin/python ${driver} put ${scribble} /NOTE/Note/scribble.note"
    )
    client.succeed("${env} ${snpy}/bin/python ${driver} sync")

    # Both materialise into library/supernote/ at the device's own relative paths, fired by that
    # sync. The .note is the one that matters most: it is the pen layer, and the only path off the
    # device for it is this mirror.
    server.wait_until_succeeds(f"test -f {MIRROR}/DOCUMENT/Document/field-notes.pdf", timeout=90)
    server.wait_until_succeeds(f"test -f {MIRROR}/NOTE/Note/scribble.note", timeout=90)
    # REAL files with the device's exact bytes — not blobs, not dangling annex symlinks. `cmp`
    # follows symlinks, so also assert each resolves to something non-empty.
    server.succeed(f"cmp ${annotated} {MIRROR}/DOCUMENT/Document/field-notes.pdf")
    server.succeed(f"cmp ${scribble} {MIRROR}/NOTE/Note/scribble.note")
    server.succeed(f"test -s {MIRROR}/DOCUMENT/Document/field-notes.pdf")
    server.succeed(f"test -s {MIRROR}/NOTE/Note/scribble.note")

    # The trigger really was the sync, and the run downloaded exactly the two files.
    watch_log = server.succeed("journalctl -u supernote-mirror-watch --no-pager -o cat")
    assert "device sync detected" in watch_log, f"watcher never saw the sync:\n{watch_log}"
    assert "store=2 downloaded=2 deleted=0" in mirror_summary(), (
        f"the mirror did not materialise both files:\n{mirror_summary()}"
    )

    # git-annex adopts what the mirror wrote, autonomously — no manual command. This is what makes
    # the tree replicated and backed up rather than merely owned by git-annex.
    # Paths are relative to the ANNEX ROOT (${libraryPath}), so they carry the `supernote/` mirror
    # prefix — not the device-relative paths used against MIRROR above.
    for adopted in ["supernote/DOCUMENT/Document/field-notes.pdf", "supernote/NOTE/Note/scribble.note"]:
        server.wait_until_succeeds(
            "sudo -u git-annex -H env HOME=/var/lib/git-annex "
            f"git -C ${libraryPath} annex whereis {adopted}",
            timeout=120,
        )

    # ── B. IDEMPOTENCE across restart ───────────────────────────────────────────────────────────
    # The mirror derives entirely from the store, so restarting the server changes nothing: no
    # re-download (content matches) and no delete (the document is still in the store).
    server.systemctl("restart supernote-server.service")
    server.wait_for_open_port(8080)
    run_mirror("store=2 downloaded=0 deleted=0")
    server.succeed(f"test -f {MIRROR}/DOCUMENT/Document/field-notes.pdf")

    # ── F. THE CATALOG COEXISTS, AND THE MIRROR STAYS OUT OF IT ─────────────────────────────────
    # Stump is up on the same tree, reaching it through the `library` group. A book planted in the
    # Books root IS indexed; the document the device synced back is the same file type but sits in
    # `supernote/`, a sibling of all three roots, so it is not — placement is what does that, and it
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
        lambda c: c.get("Books", {}).get("books") == ["clocks-of-the-long-now"],
        "the planted book is indexed",
    )
    everything = [b for lib in indexed.values() for b in lib["books"]]
    assert "field-notes" not in everything, (
        f"the mirror leaked into the catalog: {indexed}"
    )
    # And nothing is rooted inside the mirror — placement, not an ignore glob, is what keeps the
    # device's content out of the catalog.
    assert not any(lib["path"].startswith(MIRROR) for lib in indexed.values()), (
        f"a Stump library is rooted inside the mirror: {indexed}"
    )

    # ── C. DURABLE DELETE ───────────────────────────────────────────────────────────────────────
    # The device deletes the PDF (its 2-way sync propagating a device-side delete). With no upload
    # path there is no ambiguity to resolve and no baseline to consult: absent from the store means
    # gone. The .note stays, so this is the everyday case — the store still lists content, and the
    # guard has no business anywhere near it. `store=1` is what proves that: one file left, so the
    # delete is a real one rather than a guard that happened to let it through.
    client.succeed("${env} ${snpy}/bin/python ${driver} rm /DOCUMENT/Document/field-notes.pdf")
    run_mirror("store=1 downloaded=0 deleted=1")
    server.succeed(f"test ! -e {MIRROR}/DOCUMENT/Document/field-notes.pdf")
    # The handwriting is untouched — a delete in one firmware folder must not disturb another.
    server.succeed(f"test -f {MIRROR}/NOTE/Note/scribble.note")

    # ...and it is NOT resurrected: nothing can push it back, so a second run is a no-op.
    run_mirror("store=1 downloaded=0 deleted=0")
    server.succeed(f"test ! -e {MIRROR}/DOCUMENT/Document/field-notes.pdf")
    listing = client.succeed("${env} ${snpy}/bin/python ${driver} ls")
    assert "field-notes.pdf" not in listing, f"the deleted document came back in the store:\n{listing}"

    # ── D. A LOST STORE ─────────────────────────────────────────────────────────────────────────
    # Subtest C deleted a file and the store still listed content, so the guard stayed out of it.
    # THIS is the case it exists for: an empty listing at whole-device scope, which means the
    # device's entire virtual filesystem is empty — a wiped or not-yet-re-seeded store (the store is
    # rebuildable and deliberately un-backed-up, ADR-0031). Wipe it for real rather than deleting
    # the remaining file through the API, so the signal is genuine store loss and not a device that
    # happens to be empty.
    #
    # The watcher is stopped first on purpose: it fires the mirror, which `Requires=` the server, so
    # a sync line arriving mid-wipe would start the server back up underneath us.
    server.systemctl("stop supernote-mirror-watch.service")
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
    run_mirror("store=0 downloaded=0 deleted=0")
    server.succeed(f"test -f {MIRROR}/orphan.txt")
    # The handwriting from subtest A is still there too — the guard protects the whole tree, not
    # just the file planted to observe it.
    server.succeed(f"test -f {MIRROR}/NOTE/Note/scribble.note")
    body = server.succeed(f"cat {MIRROR}/orphan.txt")
    assert body == "precious-backup", f"the guarded file was clobbered: {body!r}"
    guard_log = server.succeed("journalctl -u supernote-mirror --no-pager -o cat")
    assert "the store lists NO files at all" in guard_log, (
        f"the empty store was not reported as the reason nothing was deleted:\n{guard_log}"
    )
    server.systemctl("start supernote-mirror-watch.service")

    # ── E. UNREACHABLE STORE ────────────────────────────────────────────────────────────────────
    # Point the mirror at a dead port rather than stopping the server: the mirror unit
    # Requires= supernote-server, so `systemctl start` on it would pull the server straight back up
    # and there would be nothing unreachable about the store. A refused connection at the URL is the
    # same thing from the mirror's side, and it isolates the behaviour under test from systemd's
    # dependency handling. A runtime drop-in, so it evaporates with /run.
    server.succeed(
        "mkdir -p /run/systemd/system/supernote-mirror.service.d && "
        "printf '[Service]\nEnvironment=SUPERNOTE_URL=http://127.0.0.1:9\n' "
        "> /run/systemd/system/supernote-mirror.service.d/unreachable.conf && "
        "systemctl daemon-reload"
    )
    # It must FAIL — a broken run is a failed unit, not a silent no-op — and must not have
    # touched the tree, because login happens before any library mutation.
    server.fail("systemctl start supernote-mirror.service")
    server.succeed(f"test -f {MIRROR}/orphan.txt")
    failure = server.succeed("journalctl -u supernote-mirror --no-pager -o cat")
    assert "supernote mirror: FAILED" in failure, (
        f"an unreachable store did not fail the unit loudly:\n{failure}"
    )
  '';
}
