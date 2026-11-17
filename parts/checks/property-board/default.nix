{ pkgs, ... }:

# The property board's five seams (property#5), run against the real script and the real
# job script rather than copies of either.
#
# A pure-python runCommand and NOT a NixOS VM test, for the same reason its sibling job
# check is one: everything here is a database decision or an HTTP request to loopback, and
# standing up a guest to prove that a favourite round-trips would cost minutes per
# `nix flake check` and prove nothing a VM is needed for. The one thing this cannot see —
# that the unit can open the database from inside its sandbox — is held by the profile's
# ReadWritePaths, and a VM would not have caught that either, since the trap does not
# reproduce without the real service manager.
#
# ── WHAT IT PINS, AND WHY EACH IS WORTH A GATE ─────────────────────────────────────────
#
# 1. ONE WRITER PER TABLE. The job owns `listings`, `observations` and `sweeps`; the board
#    owns `favourites`. That is the whole contract between the two halves, and the way to
#    break it is not malice but convenience — a board that creates the job's tables "just
#    in case", an endpoint that updates a status. Both are asserted here, including that
#    `connect()` creates `favourites` AND NOTHING ELSE.
#
# 2. THE SHARED-FILE HANDSHAKE, FROM BOTH SIDES. sqlite creates its files under the
#    process umask, so they land 0644 and the second of the two users cannot write them.
#    This is invisible until the first click and then reads as a permissions bug. The
#    check holds it on the job's `connect()` as well as the board's, because the job
#    creates the file first and a fix in only one of them is no fix at all.
#
# 3. DAYS ON MARKET STOPS WHEN THE LISTING DOES. Measured first_seen → last_seen, not
#    → today, or every withdrawn listing ages forever and the number silently stops
#    meaning anything.
#
# 4. A FAVOURITE POINTS AT A LISTING THAT EXISTS. The job reads this table to tell you
#    when something you favourited goes under offer; a row it can never resolve is a
#    promise that quietly never fires.
#
# 5. THE PAGE SAYS A PIN IS NOT AN ADDRESS. Asked for explicitly by the ticket, because
#    the portal fuzzes exact location and a pin acted on as a front door is the one way
#    this page can actually mislead someone.
pkgs.runCommand "check-property-board"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    set -euo pipefail
    install -D ${../../../modules/nixos/profiles/property-board.py} src/property-board.py
    install -D ${../../../modules/nixos/profiles/property-board-test.py} src/property-board-test.py
    install -D ${../../../modules/nixos/profiles/property-watch.py} src/property-watch.py
    cd src
    python3 property-board-test.py -v
    touch $out
  ''
