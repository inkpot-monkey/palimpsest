# music-sync: the acquisition-half drain that carries completed slskd downloads from
# kelpy to rk1b's beets inbox, proven end to end between two nodes.
#
# What this pins, because each part failed a plausible way if wrong:
#   * the cross-host hop itself — a file (and a nested album dir) placed in the source,
#     with NO manual command, reaches the remote inbox over the reused git-annex SSH
#     identity. This is the whole point; if the .path trigger or the ssh/rsync wiring is
#     wrong, nothing moves and a download strands in silence.
#   * the HANDOFF PERMISSIONS — the real reason this isn't a trivial `rsync`. Files land
#     owned by the ssh identity (git-annex) into an inbox owned by a DIFFERENT consumer
#     (here `beetsish`, standing in for navidrome). The consumer must be able to READ the
#     landed files and MOVE them out of the album dirs, which only works because the inbox
#     is setgid `music`, --chmod forces group-writable dirs + group-readable files, and
#     both identities share the `music` group. Get any of those wrong and beets can't
#     drain the inbox — the exact "looks delivered, silently un-consumable" failure.
#   * SOURCE CLEANUP — --remove-source-files plus the empty-dir prune must drain the
#     source to nothing, so a tight disk budget isn't held by shipped data and the .path
#     unit settles instead of re-firing forever.
{ pkgs, ... }:
let
  # Reuse the git-annex test scaffolding: a shared keypair installed on every node as the
  # git-annex user's identity AND authorized key, so git-annex@<node> SSH works at boot
  # with no testScript key exchange — exactly the channel music-sync's default identityFile
  # points at.
  helper = import ../../git-annex/tests/lib.nix { inherit pkgs; };

  source = "/var/lib/downloads";
  inbox = "/var/cache/music-inbox";
  album = "Artist - Album";
in
pkgs.testers.nixosTest {
  name = "music-sync";
  nodes = {
    # kelpy-like: has slskd's completed-downloads dir and drains it to the receiver.
    sender =
      { ... }:
      {
        imports = [
          helper.commonNode # git-annex module enabled -> installs the SSH identity
          ../default.nix # the music-sync module under test
        ];

        # The source that slskd would fill. Owned by root here; the drain runs as root
        # (its default), which reads and deletes it without any group juggling — mirroring
        # slskd's real root:media download tree.
        systemd.tmpfiles.rules = [ "d ${source} 0755 root root -" ];

        services.music-sync = {
          enable = true;
          inherit source;
          # The receiver node is addressable by its node name as a hostname.
          target = "git-annex@receiver:${inbox}";
          # identityFile defaults to the git-annex key commonNode installs; user defaults
          # to root. Leave both at their production defaults so the test exercises them.
        };
      };

    # rk1b-like: owns the beets inbox and is where beets (here `beetsish`) drains it.
    receiver =
      { pkgs, ... }:
      {
        imports = [ helper.commonNode ]; # for the git-annex user + authorized key (SSH peer)

        # rsync must be resolvable from the login PATH for the incoming `rsync --server`.
        environment.systemPackages = [ pkgs.rsync ];

        # The `music` group bridges the writing identity (git-annex) and the consuming
        # identity (beetsish / navidrome in production). git-annex is put in it exactly as
        # hosts/rk1/git-annex.nix does on the real rk1b.
        users.groups.music = { };
        users.groups.beetsish = { };
        users.users.beetsish = {
          isSystemUser = true;
          group = "beetsish";
          extraGroups = [ "music" ];
        };
        users.users.git-annex.extraGroups = [ "music" ];

        # The inbox: navidrome-analog owner, setgid `music`, group-writable — so the
        # git-annex ssh identity can write into it and the consumer can drain it. This is
        # the production `d /var/cache/music-inbox 2775 navidrome music` line. The library
        # is where the consumer moves files TO (beets inbox -> Navidrome library), same
        # filesystem so the drain is a pure rename that exercises unlink-from-album-dir.
        systemd.tmpfiles.rules = [
          "d ${inbox} 2775 beetsish music -"
          "d /var/cache/music-library 2775 beetsish music -"
        ];
      };
  };

  testScript = ''
    start_all()

    receiver.wait_for_unit("multi-user.target")
    receiver.wait_for_open_port(22)
    sender.wait_for_unit("multi-user.target")
    # The drain reuses the identity installed by this unit; it must exist before we fire.
    sender.wait_for_unit("git-annex-ssh-key.service")

    # The responsive trigger must be armed and watching the (currently empty) source.
    sender.succeed("systemctl is-active music-sync.path")

    # Drop a nested album AND a loose top-level file into the source, then DO NOTHING else
    # — no manual rsync, no `systemctl start`. The .path unit (DirectoryNotEmpty) must
    # notice and drain it across to the receiver on its own.
    sender.succeed("mkdir -p '${source}/${album}'")
    sender.succeed("echo flac-payload > '${source}/${album}/01 Track.flac'")
    sender.succeed("echo loose-payload > '${source}/loose.mp3'")

    # ...and it lands, unaided, on the far side — nested structure preserved. Use
    # wait_until_succeeds with an explicitly single-quoted path rather than wait_for_file,
    # whose internal `test -e` is unquoted and chokes on the space in the album name.
    receiver.wait_until_succeeds("test -e '${inbox}/${album}/01 Track.flac'", timeout=90)
    receiver.wait_until_succeeds("test -e '${inbox}/loose.mp3'", timeout=90)
    receiver.succeed("grep -q flac-payload '${inbox}/${album}/01 Track.flac'")

    # HANDOFF PERMISSIONS. Files land owned by the SSH identity (git-annex), into an inbox
    # owned by a different user — proving the reused-identity design, not a same-user copy.
    owner = receiver.succeed("stat -c %U '${inbox}/${album}/01 Track.flac'").strip()
    assert owner == "git-annex", f"landed file should be owned by the ssh identity, got {owner}"

    # The incoming album dir must be group `music` AND setgid, or nested files wouldn't
    # inherit the group and the consumer couldn't read/drain them.
    grp = receiver.succeed("stat -c %G '${inbox}/${album}'").strip()
    assert grp == "music", f"album dir should be group music, got {grp}"
    mode = receiver.succeed("stat -c %A '${inbox}/${album}'").strip()
    assert mode[6] in ("s", "S"), f"album dir should be setgid (found mode {mode})"

    # The consumer (beetsish, sharing `music`, standing in for beets/navidrome) must be
    # able to READ the landed file and MOVE it out of the album dir — the actual drain
    # beets performs. Read needs group-read on the file; move needs group-WRITE on the
    # album dir AND beetsish effectively holding the `music` group. Diagnostics first so a
    # failure says which of the two is missing, then assert both explicitly.
    receiver.log("album dir: " + receiver.succeed("stat -c '%A %U:%G' '${inbox}/${album}'"))
    receiver.log("landed file: " + receiver.succeed("stat -c '%A %U:%G' '${inbox}/${album}/01 Track.flac'"))
    receiver.log("beetsish groups: " + receiver.succeed("sudo -u beetsish id -nG"))

    # beetsish must effectively be in `music`, and the album dir must be group-writable —
    # index 5 of the mode string is the group-write bit (drwxrw[s]r-x).
    receiver.succeed("sudo -u beetsish sh -c 'id -nG | grep -qw music'")
    mode = receiver.succeed("stat -c %A '${inbox}/${album}'").strip()
    assert mode[5] == "w", f"album dir must be group-writable for the consumer to drain it, got {mode}"

    receiver.succeed("sudo -u beetsish cat '${inbox}/${album}/01 Track.flac' >/dev/null")
    # Same-filesystem move into the consumer's library — a pure rename, so it exercises
    # unlink-from-the-git-annex-owned-album-dir, exactly what beets does inbox -> library.
    receiver.succeed("sudo -u beetsish mv '${inbox}/${album}/01 Track.flac' /var/cache/music-library/consumed.flac")
    receiver.succeed("grep -q flac-payload /var/cache/music-library/consumed.flac")

    # SOURCE CLEANUP. --remove-source-files + the empty-dir prune must leave the source
    # completely empty, so shipped data doesn't linger and the .path unit settles.
    sender.wait_until_succeeds("test -z \"$(ls -A '${source}')\"", timeout=60)
  '';
}
