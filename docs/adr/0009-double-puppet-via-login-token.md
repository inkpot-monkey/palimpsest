# Double-puppeting via a one-time login token, not declarative `as_token`

Both bridges (jmap email, mautrix-whatsapp) double-puppet `@inkpotmonkey` so the user's own account appears to send bridged messages and auto-joins rooms. This is established with a one-time `login-matrix <access_token>` command (validated via `/whoami`), with the token persisted in the bridge DB — deliberately **not** the declarative `as_token` method.

The `as_token` double-puppet method requires the shared admin user to sit in the appservice's user namespace. Because `@inkpotmonkey` is shared across *two* appservices, tuwunel then treats each bridge as "interested" in every room the user is in — including the other bridge's rooms — and floods it with foreign `@_jmap_*` events, `cannot join a room that is not public` spam, and a fatal crypto-token error (confirmed, then reverted). The login-token method causes no namespace pollution.

## Consequences

- Double-puppet setup is a one-time manual step per bridge, not declarative; this is a known, accepted trade-off for keeping a single Matrix user shared cleanly across appservices.
- The jmap bridge additionally runs its own scoped `/sync` auto-accept loop (only invites from `@_jmap_bot`) because tuwunel has no homeserver-side auto-accept — see [0006](0006-tuwunel-matrix-homeserver.md).
