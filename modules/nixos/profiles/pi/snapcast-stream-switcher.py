#!/usr/bin/env python3
"""Auto-follow the active Snapcast stream (a Volumio-style volatile-state arbiter).

porcupineFish's snapserver hosts two sources as *separate* streams — the static
``Spotify`` librespot stream and the dynamic ``Music Assistant - …`` stream MA pushes
over the control port. The local snapclient plays whichever stream its *group* is bound
to, and snapcast 0.34 does **not** auto-follow the active stream: hit play in the other
source and the group stays put → silence. This watcher fixes that. It subscribes to
snapserver's control API and, on a clean ``idle → playing`` edge, binds the connected
client's group to the stream that just started — so play-in-either-app "just works" with
no manual ``Group.SetStream``. (docs/adr/0031-porcupinefish-sound-server-audio.md, #96.)

Design (copied from how Volumio arbitrates output; see the issue):
  * **Event-driven off stream *status*, never PCM-silence sniffing** → non-flappy.
  * **Debounced** so a stream dipping to ``idle`` between tracks does NOT count as
    "went inactive": a re-``playing`` edge only steals focus if the stream had been
    *sustained*-idle (≥ DEBOUNCE seconds) — a track-change blip on a background source
    can't yank output away from the focused one.
  * **Last-activated-wins**, with a fixed priority list only as the startup/simultaneous
    tiebreak.
  * When the *focused* stream goes sustained-idle and another stream is still playing,
    follow it (so pausing MA hands the speaker to a still-playing Spotify, and vice versa).

Volume is deliberately out of scope here: snapclient's hardware "Digital" mixer is the
single master (volume model B) and this arbiter never touches it — it only routes audio.

Config via env (set from the systemd unit):
  SNAPCAST_HOST / SNAPCAST_PORT   snapserver control endpoint (default 127.0.0.1:1705)
  SWITCHER_CLIENT_ID              snapclient hostID whose group we drive (default porcupineFish)
  SWITCHER_DEBOUNCE_SEC           sustained-idle threshold, seconds (default 5)
  SWITCHER_PRIORITY               comma-separated stream-id substrings, highest first,
                                  used only to break ties (default "Spotify")

Resilience: a dropped control connection (snapserver restart, transient blip) is caught
and reconnected internally with a fresh seed — no systemd churn. `Restart=always` in the
unit is the backstop for anything that *does* escape (an unexpected bug), not the normal
reconnect path.
"""

import json
import os
import select
import socket
import sys
import time

HOST = os.environ.get("SNAPCAST_HOST", "127.0.0.1")
PORT = int(os.environ.get("SNAPCAST_PORT", "1705"))
CLIENT_ID = os.environ.get("SWITCHER_CLIENT_ID", "porcupineFish")
DEBOUNCE = float(os.environ.get("SWITCHER_DEBOUNCE_SEC", "5"))
PRIORITY = [
    p.strip()
    for p in os.environ.get("SWITCHER_PRIORITY", "Spotify").split(",")
    if p.strip()
]


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def priority_rank(stream_id):
    """Lower is higher priority. Streams matching an earlier PRIORITY substring win a tie."""
    for i, pat in enumerate(PRIORITY):
        if pat in stream_id:
            return i
    return len(PRIORITY)


class Switcher:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.next_id = 1
        # stream_id -> {"status": "playing"|"idle"|..., "idle_since": float|None}
        self.streams = {}
        self.focused = None  # stream_id the target group is currently bound to
        self.group_id = None  # id of the group holding our client (MA may reassign it)
        # A deferred "the focused stream went idle — should we follow another?" check.
        self.reeval_at = None
        # Notifications that arrive *while blocked in* request_status() are parked here and
        # drained by the main loop, so a status read never re-enters set_stream/request_status.
        self.pending = []

    # --- control-API plumbing -------------------------------------------------
    def send(self, method, params=None):
        msg = {"id": self.next_id, "jsonrpc": "2.0", "method": method}
        self.next_id += 1
        if params is not None:
            msg["params"] = params
        self.sock.sendall((json.dumps(msg) + "\r\n").encode())
        return msg["id"]

    def read_messages(self, timeout):
        """Block up to `timeout`s for data; yield each complete JSON message decoded.

        Returns after draining whatever arrived (possibly nothing on timeout). Raises on a
        closed connection so the caller can exit and let systemd restart us.
        """
        rlist, _, _ = select.select([self.sock], [], [], timeout)
        if not rlist:
            return
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ConnectionError("snapserver closed the control connection")
        self.buf += chunk
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            line = line.strip()
            if line:
                yield json.loads(line)

    def request_status(self):
        """Fetch Server.GetStatus and return the parsed server dict (blocking, with a cap)."""
        req_id = self.send("Server.GetStatus")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            for msg in self.read_messages(deadline - time.monotonic()):
                if msg.get("id") == req_id and "result" in msg:
                    return msg["result"]["server"]
                # A notification interleaved the response. Park it for the main loop rather
                # than handling it here — acting on it now could re-enter set_stream and nest
                # another blocking request_status inside this one.
                self.pending.append(msg)
        raise ConnectionError("timed out waiting for Server.GetStatus")

    # --- snapcast model helpers ----------------------------------------------
    def target_group(self, server):
        """The group holding our connected client, or None if it isn't connected yet."""
        for group in server.get("groups", []):
            for client in group.get("clients", []):
                if client.get("id") == CLIENT_ID and client.get("connected"):
                    return group
        return None

    def adopt_group(self, group):
        """Record which group holds our client and what stream it's bound to."""
        self.group_id = group["id"] if group else None
        self.focused = group.get("stream_id") if group else None

    def set_stream(self, stream_id):
        """Bind the connected client's *current* group to `stream_id` (idempotent).

        Re-reads status so we always target the group MA has the client in *now* (MA can
        move the client into its own group), and skip the call when already bound.
        """
        group = self.target_group(self.request_status())
        if group is None:
            log(f"cannot switch to {stream_id!r}: client {CLIENT_ID!r} not connected")
            return
        self.adopt_group(group)
        if self.focused == stream_id:
            return
        self.send("Group.SetStream", {"id": group["id"], "stream_id": stream_id})
        log(f"switched output {self.focused!r} -> {stream_id!r} (group {group['id']})")
        self.focused = stream_id

    def refresh_group(self):
        """Re-read which group holds our client and what it's bound to (cheap, no switch)."""
        self.adopt_group(self.target_group(self.request_status()))

    def playing_streams(self):
        return [sid for sid, s in self.streams.items() if s["status"] == "playing"]

    # --- edge logic -----------------------------------------------------------
    def note_status(self, stream_id, status):
        """Fold one stream status into state and act on the meaningful edges."""
        prev = self.streams.get(stream_id, {"status": None, "idle_since": None})
        now = time.monotonic()

        if status == "playing":
            # A genuine (re)activation only if the stream was *sustained*-idle before —
            # not a track-change blip on a stream that was playing moments ago.
            was_recently_active = prev["status"] == "playing" or (
                prev["idle_since"] is not None and (now - prev["idle_since"]) < DEBOUNCE
            )
            self.streams[stream_id] = {"status": "playing", "idle_since": None}
            if not was_recently_active and stream_id != self.focused:
                log(f"{stream_id!r} activated -> claiming output")
                self.set_stream(stream_id)
        else:
            # Any non-playing status (idle/unknown/…) — start/keep the debounce clock.
            idle_since = prev["idle_since"] if prev["status"] != "playing" else now
            self.streams[stream_id] = {
                "status": status,
                "idle_since": idle_since or now,
            }
            if stream_id == self.focused:
                # Focused stream paused: after DEBOUNCE, hand off to another playing stream.
                self.reeval_at = now + DEBOUNCE

    def reevaluate(self):
        """Deferred check: focused stream sat idle — follow the best still-playing stream."""
        self.reeval_at = None
        focused = self.streams.get(self.focused, {})
        if focused.get("status") == "playing":
            return  # focused resumed within the debounce window; nothing to do
        candidates = self.playing_streams()
        if not candidates:
            return  # nobody is playing — leave the group put, snapclient just goes idle
        winner = min(candidates, key=priority_rank)
        if winner != self.focused:
            log(f"focused {self.focused!r} idle >{DEBOUNCE:g}s -> following {winner!r}")
            self.set_stream(winner)

    # --- notifications --------------------------------------------------------
    def handle_notification(self, msg):
        method = msg.get("method")
        params = msg.get("params") or {}
        if method == "Stream.OnUpdate":
            stream = params.get("stream") or {}
            sid = params.get("id") or stream.get("id")
            status = stream.get("status")
            if sid and status:
                self.note_status(sid, status)
        elif method == "Group.OnStreamChanged":
            # Someone (MA, snapweb) re-bound a group — keep our notion of `focused` honest.
            # Only our group matters; a re-read on the next switch corrects any drift if MA
            # has since moved the client to a different group.
            if params.get("id") == self.group_id and "stream_id" in params:
                self.focused = params["stream_id"]
        elif method in ("Client.OnConnect", "Client.OnDisconnect"):
            # Our snapclient (re)joined the server — e.g. after a snapserver restart the
            # switcher can seed before the client registers. Re-resolve its group so the
            # "hand off when the focused source pauses" logic tracks the right binding.
            client = params.get("client") or {}
            if client.get("id") == CLIENT_ID:
                self.refresh_group()

    # --- main loop ------------------------------------------------------------
    def seed(self):
        server = self.request_status()
        self.adopt_group(self.target_group(server))
        for stream in server.get("streams", []):
            sid = stream.get("id")
            status = stream.get("status", "idle")
            self.streams[sid] = {
                "status": status,
                "idle_since": None if status == "playing" else time.monotonic(),
            }
        log(
            f"seeded: focused={self.focused!r} streams={ {k: v['status'] for k, v in self.streams.items()} }"
        )
        # If the focused stream is idle but another is playing, follow it right away.
        if (
            self.focused is None
            or self.streams.get(self.focused, {}).get("status") != "playing"
        ):
            self.reeval_at = time.monotonic()

    def dispatch(self, msg):
        if "method" in msg:
            self.handle_notification(msg)

    def run(self):
        self.seed()
        while True:
            timeout = None
            if self.reeval_at is not None:
                timeout = max(0.0, self.reeval_at - time.monotonic())
            for msg in self.read_messages(timeout if timeout is not None else 30.0):
                self.dispatch(msg)
            # Drain notifications parked by any request_status() run this iteration. Iterative
            # (not recursive), so a switch triggered here can safely re-read status in turn.
            while self.pending:
                self.dispatch(self.pending.pop(0))
            if self.reeval_at is not None and time.monotonic() >= self.reeval_at:
                self.reevaluate()


def main():
    while True:
        try:
            with socket.create_connection((HOST, PORT), timeout=10) as sock:
                sock.settimeout(None)
                log(f"connected to snapserver control at {HOST}:{PORT}")
                Switcher(sock).run()
        except (ConnectionError, OSError, json.JSONDecodeError) as exc:
            log(f"control connection error: {exc}; reconnecting in 5s")
            time.sleep(5)


if __name__ == "__main__":
    main()
