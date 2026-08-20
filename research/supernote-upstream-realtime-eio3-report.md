# DRAFT — upstream bug report for `allenporter/supernote` (NOT FILED)

Written 2026-08-18 during the palimpsest#112 hardware acceptance pass. **This has not been
filed.** It is here for review first; when approved, file it at
<https://github.com/allenporter/supernote/issues> and replace this banner with the issue link.

Everything below is reproduced from a live deployment (rk1b, supernote 0.17.0, a real Supernote
Nomad A6 X2 on firmware Chauvet `E103.2606141001.2389`), not from reading the source.

______________________________________________________________________

## Title

Realtime Socket.IO channel can never accept a real device: `allow_eio3=True` is a JavaScript-only
option and is silently discarded in Python

## Body

### Summary

`supernote/server/socket.py` constructs the Socket.IO server with `allow_eio3=True`, intending
Engine.IO v3 compatibility. **That keyword does not exist in `python-socketio` or
`python-engineio` at any version.** It is an option from the *JavaScript* socket.io server
(`new Server(srv, { allowEIO3: true })`). Because both Python libraries end their `__init__`
signatures in `**kwargs`, the argument is forwarded from socketio to engineio and then dropped
with no error and no warning.

The consequence is that a real Supernote device — which connects with `EIO=3` — is refused at
the handshake, and has been at every release. The server starts cleanly and gives no indication
anything is wrong.

### Environment

- `supernote` 0.17.0
- `python-socketio` 5.16.3, `python-engineio` 4.13.3, Python 3.13, aiohttp async mode
- Client: Supernote Nomad A6 X2, stock Private Cloud sync, `User-Agent: okhttp/3.12.12`

### Reproduction

Point a real device at the server and sync. Every ~5s the device retries and is refused:

```
GET /socket.io/?sign=…&random=…&EIO=3&transport=websocket&type=SN078D…&token=… HTTP/1.1" 400
```

Response body:

```
"The client is using an unsupported version of the Socket.IO or Engine.IO protocols"
```

Without a device, `curl` reproduces it exactly:

```console
$ curl -i 'http://localhost:8080/socket.io/?EIO=3&transport=polling'
HTTP/1.1 400 Bad Request
"The client is using an unsupported version of the Socket.IO or Engine.IO protocols"
```

### Root cause

1. `supernote/server/socket.py:52-55`

   ```python
   self._sio = socketio.AsyncServer(
       async_mode="aiohttp",
       cors_allowed_origins="*",
       allow_eio3=True,
   )
   ```

1. `socketio/base_server.py:18-19` — every unrecognised kwarg is forwarded verbatim:

   ```python
   def __init__(self, ..., **kwargs):
       engineio_options = kwargs
   ```

1. `engineio/base_server.py:35-41` — `__init__` also ends in `**kwargs` and **discards**
   anything it does not name. `allow_eio3` is not a parameter, so it vanishes here.

1. `engineio/async_server.py:254` — the gate is therefore unconditional:

   ```python
   sid = query['sid'][0] if 'sid' in query else None
   if sid is None and query.get('EIO') != ['4']:
       ...  # 400
   ```

`grep -r allow_eio3` over the full source trees of `python-socketio` (v5.0.0, v5.11.0, v5.16.3)
and `python-engineio` (v3.14.1, v4.0.0, v4.13.3) returns **zero matches**, source and docs
included. There is no version constraint that makes the current code work.

### There is no pin that fixes this

`python-engineio` 4.x implements Engine.IO v4 only. The last series that speaks v3 natively is
3.x (`engineio/server.py:352` in v3.14.1: `if sid is None and query.get('EIO') not in [['2'], ['3']]`), which pairs with `python-socketio` 4.x. Both are long EOL.

### What we tested

We patched `python-engineio` 4.13.3 locally, purely to find where the wall actually is:

1. `async_server.py` — accept `EIO=3` at the gate.
1. `async_socket.py` — reply `PONG` to a client-sent `PING`. Engine.IO v3 reverses the
   heartbeat (client pings, server pongs); unpatched, a client `PING` falls through
   `receive()` to `raise UnknownPacketError`, and the v4 server-driven ping times out waiting
   for a `PONG` a v3 client never sends.

Result on real hardware: the device handshake went **400 → 101 Switching Protocols**. It got no
further. `socket.py`'s `connect` handler never fired — neither its success line nor either of
its two rejection lines (`invalid signature`, `invalid token`) appeared. The Engine.IO layer
now negotiates, but `python-socketio` 5.x speaks Socket.IO protocol **v5** while the device
pairs EIO3 with Socket.IO **v2**, so the CONNECT packet is never parsed.

So full device support needs Socket.IO v2 *and* Engine.IO v3 — i.e. the 4.x/3.x pairing, or a
hand-rolled implementation of the two protocols.

### Secondary observation: the push path is currently unreachable

Independently of the above, in 0.17.0 nothing can send on this channel:

- `SocketIOServerManager.send_message()` — the only method emitting a payload to a user room —
  has **no callers** anywhere in the package.
- `server/app.py:398` calls `setup_socketio(app, config)` and **discards the return value**; the
  manager is not stored on the app or referenced elsewhere.

Connected, the channel only answers `ClientMessage: STATUS` with `"true"`, echoes `ratta_ping`,
and logs delivery ACKs. So the practical impact of the handshake bug is currently nil — file
sync and the planner routes are plain REST and unaffected — but the dead push path is worth
knowing about, since it means the feature cannot be exercised end-to-end today.

### Suggested resolutions

Any of these would be an improvement; the first is the cheapest and the most valuable:

1. **Remove `allow_eio3=True`** and document that the realtime channel requires an Engine.IO v4
   client, so the limitation is visible rather than implied. A `TypeError` would have been
   better than silence here — consider asserting the kwarg set.
1. If device support is intended, implement Socket.IO v2 / Engine.IO v3 explicitly, or pin the
   4.x/3.x library pairing behind an extra.
1. Wire up `send_message()` (or remove it) so the push path is not unreachable code.

### Note for the Python libraries

Not a bug in `python-socketio`/`python-engineio`, but worth mentioning upstream there too: both
accept and silently drop unknown constructor kwargs, which is what let this survive. A warning
on unrecognised options would have surfaced it immediately.
