{ pkgs, ... }:

# The property-watch detector's three seams (property#4, property#6), run against the real
# script rather than a copy of it.
#
# A pure-python runCommand and NOT a NixOS VM test, on purpose: everything under test here is a
# pure transformation (page bytes in, prose out) or a database decision, and standing up a guest
# to prove that `<br/>` becomes a newline would cost minutes per `nix flake check` and prove
# nothing a VM is needed for. The one thing this cannot see — that hermes can actually run the
# script inside its sandbox — is covered by the profile's ReadWritePaths and was found the hard
# way; a VM here would not have caught it either.
#
# ── WHAT IT PINS, AND WHY EACH IS WORTH A GATE ───────────────────────────────────────────────
#
# 1. STABLE BYTES. This job's whole economy is that `--monitor-script` hashes identical output
#    on a quiet day and the model is never woken. Prose is the largest thing that has ever gone
#    into that output, and the cheapest way to break the suppression is to let something
#    unordered — a dict of key-info facts, the order detail pages came back in — reach stdout.
#    Two runs over the same world must produce the same bytes or the job costs a model call
#    every morning, silently and forever.
#
# 2. THE REQUEST BUDGET. "Only newly seen listings are fetched" is a promise to OnTheMarket,
#    whose terms are the reason this source was chosen over richer ones (property#1). It is
#    invisible in the output — a job that re-fetched all ~275 detail pages daily would look
#    exactly like one that did not — so nothing but a test can hold it.
#
# 3. A FAILED DETAIL FETCH KEEPS THE LISTING. The worst available outcome is a listing dropped
#    because its description 500'd: it reads as never having existed, and three runs later the
#    job reports a withdrawal that never happened.
#
# 4. NO SERVICE CHARGE IS PARSED OUT OF PROSE. The script stores "£697 per annum" as that
#    string; turning it into 697 is the judgement the detect/judge boundary assigns to the
#    model. A live page found during this work proves why: its prose says "Service Charge: £540
#    (Quarterly)" while the portal's own field says "£2,160 per annum". A regex would have
#    reported £540, and a number in a database is believed.
pkgs.runCommand "check-property-watch"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    set -euo pipefail
    install -D ${../../../modules/nixos/profiles/property-watch.py} src/property-watch.py
    install -D ${../../../modules/nixos/profiles/property-watch-test.py} src/property-watch-test.py
    cd src
    python3 property-watch-test.py -v
    touch $out
  ''
