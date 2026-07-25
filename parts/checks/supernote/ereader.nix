# Acceptance test for the ereader round-trip (ADR-0031 v2, palimpsest#107).
#
# Drives the round-trip end-to-end against the REAL packaged server + reconciler, on a two-node
# virtual LAN. The `client` node stands in for the Nomad: it opens sync sessions (the reconcile's
# only sync-coupled trigger) and, acting as the device's 2-way sync, adds/deletes files in the store.
#
#   A. SEND (one-shot). Drop a file in library/ereader-outbox/, drive a device sync → the reconcile
#      fires off that sync, uploads it to the store (it appears in the device's own list_folder),
#      materialises it down into library/ereader/, and CLEARS the outbox.
#   B. BASELINE across restart. Restart the server, reconcile again → no spurious re-push or delete
#      (send=0 downloaded=0 deleted=0): the persisted baseline survived the restart.
#   C. DURABLE DELETE. The device (client) deletes the file from the store; reconcile → it is
#      removed from library/ereader/ AND not re-pushed (the outbox is empty, so it stays gone).
#   D. STORE-LOSS GUARD. With an empty store and an empty baseline, a file planted directly in
#      library/ereader/ is NOT deleted — a wiped/rebuildable store must never nuke the backed-up tree.
#
# sops is bypassed exactly as parts/checks/supernote/default.nix does: dummy age key + forced
# secret paths pointing at plain /etc files, so no real decryption happens in the sandbox.
{
  self,
  pkgs,
  inputs,
}:
let
  # The account the fork bootstraps from the mock credential (must be a valid email — the fork
  # validates EMAIL_REGEX on register). Reused verbatim by the client-side device driver.
  account = "device@example.com";
  password = "sync-secret-123";
  libraryPath = "/var/lib/library";

  # A python interpreter with the `supernote` library importable — the same construction the
  # profile uses for the reconciler (toPythonModule re-exposes the application's modules). Drives
  # the device APIs (sync_start, list_folder, delete_by_path) from the client, as a real device would.
  snpy = pkgs.python313.withPackages (ps: [ (ps.toPythonModule pkgs.supernote) ]);

  # A tiny device driver: `sync` opens a sync session (the reconcile's only trigger); `ls` prints
  # the ereader folder listing as `<path_display>\t<content_hash>` lines; `rm <path>` deletes a file
  # from the store (the device's 2-way sync propagating a device-side delete up).
  driver = pkgs.writeText "sn-ereader-driver.py" ''
    import asyncio
    import os
    import sys

    from supernote.client import Supernote
    from supernote.client.exceptions import NotFoundException

    URL = os.environ["URL"]
    USER = os.environ["SN_USER"]
    PW = os.environ["SN_PASS"]


    async def main():
        cmd = sys.argv[1]
        async with await Supernote.login(USER, PW, host=URL) as sn:
            if cmd == "sync":
                await sn.device.sync_start("TEST-DEVICE")
                print("sync started")
            elif cmd == "ls":
                try:
                    listing = await sn.device.list_folder(
                        "/DOCUMENT/Document/ereader", recursive=True
                    )
                except NotFoundException:
                    return
                for e in listing.entries:
                    print(f"{e.path_display}\t{e.content_hash}")
            elif cmd == "rm":
                await sn.device.delete_by_path(sys.argv[2])
                print("deleted")


    asyncio.run(main())
  '';

  env = "URL=http://server:8080 SN_USER=${account} SN_PASS=${password}";
in
pkgs.testers.nixosTest {
  name = "supernote-ereader-reconcile-test";

  nodes = {
    server =
      { lib, ... }:
      {
        imports = [
          inputs.sops-nix.nixosModules.sops
          inputs.impermanence.nixosModules.impermanence
          (self + /modules/nixos/profiles/supernote.nix)
        ];

        options.custom.profiles.impermanence.enable = lib.mkEnableOption "impermanence (test stub)";

        config = {
          _module.args.self = self;

          custom.profiles.supernote.enable = true;
          # The feature under test: point it at a plain test dir (no NVMe/git-annex mount here).
          custom.profiles.supernote.ereader = {
            enable = true;
            inherit libraryPath;
          };

          # The reconciler reads/writes library/ereader{,-outbox}/ as the `supernote` user via the
          # `library` group, and both dirs are created owned by the tree owner `git-annex` — mirror
          # both here so the ownership/permission path is exercised, not stubbed.
          users.groups.library.gid = 977;
          users.groups.git-annex = { };
          users.users.git-annex = {
            isSystemUser = true;
            group = "git-annex";
          };

          # Satisfy the sops assertions without a real key/file, and force the two credential
          # secrets to plain files (same bypass as the #92 server test).
          sops.age.keyFile = "/etc/dummy-sops-key";
          sops.defaultSopsFile = pkgs.writeText "dummy-sops.yaml" "";
          sops.validateSopsFiles = false;
          sops.secrets."supernote/user".path = lib.mkForce "/etc/mock-supernote-user";
          sops.secrets."supernote/password".path = lib.mkForce "/etc/mock-supernote-password";
          environment.etc."mock-supernote-user".text = account;
          environment.etc."mock-supernote-password".text = password;

          virtualisation.memorySize = 2048;
        };
      };

    client = {
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  testScript = ''
    def reconcile_summary():
        # The newest `sent=.. downloaded=.. deleted=..` summary line from the reconcile unit.
        log = server.succeed("journalctl -u supernote-ereader-reconcile --no-pager -o cat")
        lines = [ln for ln in log.splitlines() if "ereader reconcile: sent=" in ln]
        assert lines, f"no reconcile summary line found:\n{log}"
        return lines[-1]


    start_all()

    # The server, its account, the ereader folders, and the sync watcher all come up.
    server.wait_for_unit("supernote-server.service")
    server.wait_for_open_port(8080)
    server.wait_for_unit("supernote-account-bootstrap.service")
    server.wait_for_unit("supernote-ereader-dir.service")
    server.wait_for_unit("supernote-ereader-watch.service")

    # library/ereader/ and the sibling one-shot outbox both exist, group `library`, setgid (2770),
    # owned by the tree owner git-annex (the "stays git-annex-owned, group-readable" AC).
    for d in ["ereader", "ereader-outbox"]:
        perms = server.succeed("stat -c '%a %U %G' ${libraryPath}/" + d).strip()
        assert perms == "2770 git-annex library", f"unexpected {d} dir perms: {perms}"

    client.wait_until_succeeds("curl -sf -o /dev/null http://server:8080/api/csrf", timeout=60)

    # ── A. SEND (one-shot) ──────────────────────────────────────────────────────────────────────
    # Drop a book in the outbox (group-readable to the reconciler, as a real drop would be).
    server.succeed("echo -n 'the-quick-brown-fox' > ${libraryPath}/ereader-outbox/hello.txt")
    server.succeed("chown git-annex:library ${libraryPath}/ereader-outbox/hello.txt")
    server.succeed("chmod 664 ${libraryPath}/ereader-outbox/hello.txt")
    md5 = server.succeed("md5sum ${libraryPath}/ereader-outbox/hello.txt").split()[0]

    # Drive a device-initiated sync from the client — the reconcile's ONLY trigger.
    client.succeed("${env} ${snpy}/bin/python ${driver} sync")

    # The reconcile (fired by the watcher off that sync) sends the file up so it is reachable to the
    # device: it appears in the device's own list_folder under /DOCUMENT/Document/ereader.
    client.wait_until_succeeds(
        "${env} ${snpy}/bin/python ${driver} ls | grep -q ereader/hello.txt", timeout=90
    )
    listing = client.succeed("${env} ${snpy}/bin/python ${driver} ls")
    assert md5 in listing, f"sent md5 {md5} not found in device listing:\n{listing}"

    # It is ALSO materialised down into library/ereader/ (the mirror, backed up + Stump-indexed)...
    server.wait_until_succeeds("test -f ${libraryPath}/ereader/hello.txt", timeout=30)
    body = server.succeed("cat ${libraryPath}/ereader/hello.txt")
    assert body == "the-quick-brown-fox", f"mirrored file has wrong content: {body!r}"
    # ...and the outbox is CLEARED (one-shot send, not a re-applied mirror).
    server.succeed("test ! -e ${libraryPath}/ereader-outbox/hello.txt")

    # The trigger really was the sync: the watcher logged the detection, and the reconcile ran and
    # sent + downloaded exactly the one file.
    watch_log = server.succeed("journalctl -u supernote-ereader-watch --no-pager -o cat")
    assert "device sync detected" in watch_log, f"watcher never saw the sync:\n{watch_log}"
    assert "sent=1 downloaded=1 deleted=0" in reconcile_summary(), (
        f"send pass did not round-trip the one file:\n{reconcile_summary()}"
    )

    # ── B. BASELINE across restart ──────────────────────────────────────────────────────────────
    # Restart the server, then reconcile again (a direct start is a faithful re-run and sidesteps the
    # watcher's debounce window). The baseline persisted, so this is a clean no-op: nothing to send
    # (outbox empty), nothing to download (mirror matches), nothing to delete (file still in store).
    server.systemctl("restart supernote-server.service")
    server.wait_for_open_port(8080)
    server.systemctl("start supernote-ereader-reconcile.service")
    assert "sent=0 downloaded=0 deleted=0" in reconcile_summary(), (
        f"restart caused a spurious re-push or delete:\n{reconcile_summary()}"
    )
    server.succeed("test -f ${libraryPath}/ereader/hello.txt")

    # ── C. DURABLE DELETE ───────────────────────────────────────────────────────────────────────
    # The device deletes the book from the store (its 2-way sync propagating a device-side delete).
    # This runs AFTER the section-B server restart, so it also proves the baseline genuinely survived
    # that restart: the delete only propagates because the baseline still remembers hello.txt was
    # present — a lost baseline would silently swallow the delete (hello.txt would not be "in the
    # baseline", so the mirror would keep it), and this assertion would fail.
    client.succeed("${env} ${snpy}/bin/python ${driver} rm /DOCUMENT/Document/ereader/hello.txt")
    server.systemctl("start supernote-ereader-reconcile.service")
    # It is removed from the mirror (was in the baseline, now gone from the store = real delete)...
    server.succeed("test ! -e ${libraryPath}/ereader/hello.txt")
    assert "sent=0 downloaded=0 deleted=1" in reconcile_summary(), (
        f"device delete did not propagate down:\n{reconcile_summary()}"
    )
    # ...and it is NOT re-pushed: another reconcile leaves it gone from both the store and the mirror.
    server.systemctl("start supernote-ereader-reconcile.service")
    assert "sent=0 downloaded=0 deleted=0" in reconcile_summary(), (
        f"a deleted book was resurrected:\n{reconcile_summary()}"
    )
    server.succeed("test ! -e ${libraryPath}/ereader/hello.txt")
    listing = client.succeed("${env} ${snpy}/bin/python ${driver} ls")
    assert "hello.txt" not in listing, f"deleted book came back in the store:\n{listing}"

    # ── D. STORE-LOSS GUARD ─────────────────────────────────────────────────────────────────────
    # The store is now empty and the baseline is empty (the delete above reset it). A file planted
    # DIRECTLY in the mirror (never in the store, never in the baseline) must survive: a rebuildable
    # store that came up empty must never delete from the backed-up tree.
    server.succeed("echo -n 'precious-backup' > ${libraryPath}/ereader/orphan.txt")
    server.succeed("chown git-annex:library ${libraryPath}/ereader/orphan.txt")
    server.systemctl("start supernote-ereader-reconcile.service")
    server.succeed("test -f ${libraryPath}/ereader/orphan.txt")
    assert "sent=0 downloaded=0 deleted=0" in reconcile_summary(), (
        f"store-loss guard failed — it mutated the backed-up tree:\n{reconcile_summary()}"
    )
    body = server.succeed("cat ${libraryPath}/ereader/orphan.txt")
    assert body == "precious-backup", f"guarded file was clobbered: {body!r}"
  '';
}
