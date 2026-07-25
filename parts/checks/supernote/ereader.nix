# Acceptance test for the outbound `ereader` push (ADR-0031, palimpsest#94).
#
# Drives AC #4 end-to-end against the REAL packaged server + push, on a two-node virtual LAN:
#   1. plant a file in library/ereader/ (the git-annex tree the push reads);
#   2. drive a device-initiated sync from the `client` node (device.sync_start), which is the
#      ONLY thing that may trigger the push — no timer, no file-watcher;
#   3. assert the file lands in the fork store reachable to the device (it appears in the device
#      list_folder under /DOCUMENT/Document/ereader with the planted file's md5); and
#   4. re-run the push and assert it transfers nothing (md5-idempotent — uploaded=0).
#
# It also proves the trigger is sync-coupled: the watcher's journal shows it fired off the
# server's synchronous/start access-log line, and the push only ran because of it.
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
  # validates EMAIL_REGEX on register). Reused verbatim by the client-side sync/list driver.
  account = "device@example.com";
  password = "sync-secret-123";
  libraryPath = "/var/lib/library";

  # A python interpreter with the `supernote` library importable — the same construction the
  # profile uses for the push (toPythonModule re-exposes the application's modules). Drives the
  # device APIs (sync_start, list_folder) from the client node, as a real device would.
  snpy = pkgs.python313.withPackages (ps: [ (ps.toPythonModule pkgs.supernote) ]);

  # A tiny device driver: `sync` opens a sync session (the push's only trigger); `ls` prints the
  # ereader folder listing as `<path_display>\t<content_hash>` lines for the assertions.
  driver = pkgs.writeText "sn-ereader-driver.py" ''
    import asyncio
    import os
    import sys

    from supernote.client import Supernote

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
                listing = await sn.device.list_folder(
                    "/DOCUMENT/Document/ereader", recursive=True
                )
                for e in listing.entries:
                    print(f"{e.path_display}\t{e.content_hash}")


    asyncio.run(main())
  '';

  env = "URL=http://server:8080 SN_USER=${account} SN_PASS=${password}";
in
pkgs.testers.nixosTest {
  name = "supernote-ereader-test";

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

          # The push reads library/ereader/ as the `supernote` user via the `library` group, and
          # the ereader dir is created owned by the tree owner `git-annex` — mirror both here so
          # the ownership/permission path is exercised, not stubbed.
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
    start_all()

    # The server, its account, the ereader folder, and the sync watcher all come up.
    server.wait_for_unit("supernote-server.service")
    server.wait_for_open_port(8080)
    server.wait_for_unit("supernote-account-bootstrap.service")
    server.wait_for_unit("supernote-ereader-dir.service")
    server.wait_for_unit("supernote-ereader-watch.service")

    # AC #1: library/ereader/ exists, group `library`, setgid (2770), owned by the tree owner.
    perms = server.succeed("stat -c '%a %U %G' ${libraryPath}/ereader").strip()
    assert perms == "2770 git-annex library", f"unexpected ereader dir perms: {perms}"

    # 1. Plant a file in ereader/ (group-readable to the push, as a real drop would be).
    server.succeed("echo -n 'the-quick-brown-fox' > ${libraryPath}/ereader/hello.txt")
    server.succeed("chown git-annex:library ${libraryPath}/ereader/hello.txt")
    server.succeed("chmod 664 ${libraryPath}/ereader/hello.txt")
    md5 = server.succeed("md5sum ${libraryPath}/ereader/hello.txt").split()[0]

    client.wait_until_succeeds("curl -sf -o /dev/null http://server:8080/api/csrf", timeout=60)

    # 2. Drive a device-initiated sync from the client — the push's ONLY trigger.
    client.succeed("${env} ${snpy}/bin/python ${driver} sync")

    # 3. The push (fired by the watcher off that sync) uploads the file so it is reachable to the
    #    device: it appears in the device's own list_folder under /DOCUMENT/Document/ereader.
    client.wait_until_succeeds(
        "${env} ${snpy}/bin/python ${driver} ls | grep -q ereader/hello.txt", timeout=90
    )
    listing = client.succeed("${env} ${snpy}/bin/python ${driver} ls")
    assert md5 in listing, f"planted md5 {md5} not found in device listing:\n{listing}"

    # The trigger really was the sync (AC #3): the watcher logged the detection, and the push ran
    # and uploaded exactly the one file.
    watch_log = server.succeed("journalctl -u supernote-ereader-watch --no-pager -o cat")
    assert "device sync detected" in watch_log, f"watcher never saw the sync:\n{watch_log}"
    push_log = server.succeed("journalctl -u supernote-ereader-push --no-pager -o cat")
    assert "uploaded=1 skipped=0" in push_log, f"first push did not upload the file:\n{push_log}"

    # 4. Re-run the push: md5-idempotent, transfers nothing. A direct restart is a faithful re-run
    #    and sidesteps the watcher's debounce window; `restart` blocks until the oneshot finishes,
    #    so its summary is the newest one in the journal.
    server.systemctl("restart supernote-ereader-push.service")
    push_log = server.succeed("journalctl -u supernote-ereader-push --no-pager -o cat")
    summaries = [ln for ln in push_log.splitlines() if "ereader push: uploaded=" in ln]
    assert summaries, f"no push summary line found:\n{push_log}"
    assert "uploaded=0 skipped=1" in summaries[-1], (
        f"re-run was not a no-op transfer:\n{summaries[-1]}"
    )
  '';
}
