# A hand-written JMAP↔Matrix email bridge, with per-thread rooms

Email-to-Matrix bridging is done by a bespoke Rust appservice (`pkgs/jmap-matrix-bridge`, wired via `modules/nixos/services/jmap-bridge/`) that talks JMAP to Stalwart and the appservice API to tuwunel. We built our own rather than adopt an off-the-shelf email bridge so the behaviour — threading model, body rendering, double-puppeting, retry/submission semantics — is fully under our control and testable in a VM round-trip check (`parts/checks/jmap-bridge/`).

The central domain decision is that a bridged conversation's Matrix room is scoped **per email thread**, not per correspondent: an outbound reply shares the inbound JMAP thread and references its real `Message-ID`, and a contact's reply lands back in the same room. Rooms are grouped under a single private space named for the user's own address.

## Consequences

- The threading model is a deliberate boundary choice; "one room per contact" was rejected in favour of "one room per thread".
- Owning the bridge means owning the bug surface: the bridge carries hard-won regression tests for issues that only a real populated mailbox exposed (self-ingestion of the Sent copy, the appservice echo loop, CASCADE-wiping room bindings on restart). Don't "simplify" those guards away.
