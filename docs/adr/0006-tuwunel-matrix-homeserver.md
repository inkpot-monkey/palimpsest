# tuwunel as the Matrix homeserver

The fleet's Matrix homeserver is `tuwunel` (conduwuit lineage), configured in `modules/nixos/profiles/matrix/`. It replaced an earlier Dendrite/Conduit setup. The deciding factor is that tuwunel loads bridge registrations **declaratively** from an `appservice_dir`, which fits this repo's declarative-everything model: each bridge profile drops its registration YAML into the directory and a pre-start globs them in — no manual #admins-room dance to register appservices.

## Consequences

- Bridges integrate by contributing a registration file to tuwunel's appservice dir, not by runtime admin commands.
- tuwunel quirks are now load-bearing: its local media provider doesn't create its own root (a pre-start must `mkdir /var/lib/tuwunel/media`), and it has no homeserver-side auto-accept for invites (`auto_join_rooms` is registration-only), which is why double-puppeting is handled bridge-side (see [0009](0009-double-puppet-via-login-token.md)).

## Considered Options

- Dendrite/Conduit — the prior setup; swapped out for tuwunel's declarative appservice loading and conduwuit-lineage feature set.
