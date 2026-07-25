# Supernote Nomad — transport round-trip spike (#66)

De-risking spike for the self-hosted document library. Ran the chosen transport
against the **real** device and observed both directions end-to-end.

## Test rig

- **Device:** Supernote Nomad (A6 X2), firmware **Chauvet 3.29.42**, equipment
  `SN078D10010247`, device class **N6**. On home Wi-Fi as `192.168.1.33`.
- **Server host:** `rk1b` (aarch64 NixOS), LAN `192.168.1.23`, tailnet `100.94.98.119`.
- **Network path tested:** device → server over the **home LAN, plain HTTP**.
- Everything below was a **throwaway** standup under `~/supernote-spike/` on rk1b —
  no production Nix modules were written (planning-mode map).

## Headline result

| Leg | Transport | Result |
|---|---|---|
| **Annotations-BACK** (device → server) | `allenporter/supernote` Private Cloud | ✅ **Proven, automatic** on sync |
| **Books-OUT** (server → device) | `allenporter/supernote` Private Cloud | ❌ **Not supported** (server is receiver/processor only) |
| **Books-OUT** (server → device) | **native WebDAV** (NetVirtualDisk) | ✅ **Proven** — browse + download + open, manual per-file |

**Consequence:** the #65 assumption that `allenporter/supernote` gives "hands-off auto
two-way sync **including** the books-out direction" is **wrong**. That server ingests
and processes device uploads; it does not push server-side files down to the device.
The two legs need **two different mechanisms** (or WebDAV for both, manually). This
re-opens the books-OUT half of the transport decision — see the new decision ticket.

## Leg 1 — Annotations-BACK via `allenporter/supernote` (PROVEN)

- `allenporter/supernote` **v0.16.0**, Python 3.13. Bound `0.0.0.0:8080` (device API) +
  `0.0.0.0:8081` (MCP). Device bound via **Settings → Sync → Private Cloud**,
  `http://192.168.1.23:8080`, email/password (plain HTTP accepted — no TLS needed).
- Login + equipment-bind handshake succeeded (`login/equipment`, `bindEquipment` → 200).
- One manual **Sync** pushed the device's whole library **up**: **68 `.note`**,
  **35 PDF/EPUB**, plus **`.mark` sidecars**.
- **`.mark` = the annotation layer for PDFs/EPUBs**, stored as a separate sidecar file
  next to the original document — annotations on books are **not** flattened into the PDF.
  (Matters for the conversion pipeline, #68.)
- The **"App Data Sync failed"** popup on the device is the **app-data/settings channel
  (broken socket.io, below)**, *not* document sync — documents round-tripped fine despite it.

### `.note` conversion validated on real 3.29.42 output (closes #63's open risk)

- `supernote-tool` / `supernotelib` (bundled in the same package) converted a freshly
  synced notebook: `supernote convert -t png` and `-t pdf` both succeeded.
- File was genuine current-firmware: signature `SN_FILE_VER_20260016`,
  `APPLY_EQUIPMENT: N6`. Rendered PNG showed crisp, high-fidelity handwriting on the
  dotted-grid background. #63 could only *assume* 3.29.42 would parse — now confirmed.

### The socket.io realtime channel is broken (but non-fatal to upload)

- Device opens `GET /socket.io/?...&transport=websocket&EIO=3` → **HTTP 500**, retrying
  every ~5 s.
- Root cause: `aiohttp_asgi.get_response()` raises `RuntimeError` when the mounted ASGI
  app finishes without an HTTP `response` — exactly what a **websocket** scope does.
  **`aiohttp_asgi` cannot bridge ASGI websockets**, so the socket.io realtime push
  never works in this deployment.
- Impact: no realtime "something changed, pull now" push. Manual sync still uploads fine;
  it is the likely reason server-side files are never pulled (Leg 2).

## Leg 2 — Books-OUT via `allenporter/supernote` (DISPROVEN)

Injected `SPIKE-books-out.pdf` server-side via the `supernote cloud upload` CLI into the
device's built-in `DOCUMENT` folder. The device never downloaded it. Why:

- The file **is** correctly registered: `f_user_file` row with
  `directory_id = <DOCUMENT>`, `is_active=Y`, but `storage_key` ends in **`-WEB`**
  (web origin) vs **`-247`** (equipment no.) for device files.
- It is **not** in `f_summary` (processor didn't index it), `t_schedule_task` /
  `t_schedule_task_group` have **0 rows** (no download queued), and the device's sync
  sequence calls **`POST /api/file/schedule/group/all` → 404** (unimplemented; the
  server only has `/api/schedule/...`).
- v2 `list_folder` is "list **folders** for sync selection" only; the device pulls
  content via `download_v3` → signed `/api/oss/download`, which it never invoked for
  the injected file.
- The **project README** describes the server purely as a **receiver/processor** of
  device uploads — no documented server→device push, no realtime, no two-way claim.
  The issue tracker has no external traffic on this (Renovate bot only).

## Leg 2′ — Books-OUT via native WebDAV (PROVEN)

- `hacdias/webdav` **v5.13.0** (`nixpkgs#webdav`) on `0.0.0.0:8082`, **plain HTTP**,
  basic auth (`nomad`/`spikepass1`), `directory` = a throwaway library dir, `permissions: CRUD`.
- Device: **NetVirtualDisk / ServerLink** app → **HTTP**, host `192.168.1.23`, port `8082`,
  path `/`, username + password.
- Result: device authenticated (`192.168.1.33` in the webdav log), **listed** the share,
  and **downloaded + opened** `SPIKE-books-out.pdf`. Books-OUT works — **manual per-file**
  (tap to download to read; long-press → Upload to send back).
- Plain HTTP over the LAN sidesteps #62's open "self-signed cert tolerance" question.
  (HTTPS/self-signed still untested — not needed on a trusted LAN/tailnet path.)

## Cross-cutting gotchas for the spec

1. **Firewall interface scoping (rk1b).** rk1b's NixOS firewall accepts on `tailscale0`
   (trusted) only; the LAN interface `end0` blocks everything but ssh. From a same-subnet
   host the LAN path to `:8080` was **HTTP 000** while the tailnet path was **200**. Each
   transport port had to be opened on `end0` (`iptables -I nixos-fw 1 -i end0 -p tcp --dport <port> -j nixos-fw-accept`). **The module must open the transport port on the
   LAN interface**, or route the device to `tailscale0` via a subnet router. Since the
   device is on the same LAN as rk1b, **direct LAN is the simplest path — no subnet router
   strictly required for the at-home case** (revisit for away-sync).
1. **NixOS packaging.** rk1b has no docker/podman/nix-ld/system-python, and `supernote`
   is **not in nixpkgs**. The spike ran it via a `uv` venv on **nixpkgs** Python 3.13
   (uv's own managed CPython is a generic dynamic binary NixOS can't exec) with
   `LD_LIBRARY_PATH=<stdenv.cc.cc.lib>/lib:<zlib>/lib` for the numpy/Pillow manylinux
   wheels. A production module must package it properly (uv2nix/poetry2nix, or an
   FHS/nix-ld env). `hacdias/webdav` is already a clean single binary in nixpkgs.
1. **Two transports, two ports.** If both legs are kept: `allenporter/supernote` (:8080)
   for auto annotations-back + processing, **and** a WebDAV server for books-out. WebDAV
   alone can do **both** legs (books-out + manual annotation-upload) from one server — the
   trade is annotations-back becomes **manual per-file** instead of automatic.

## Recipe (throwaway, reproduce the spike)

```sh
# on rk1b — allenporter/supernote (annotations-back + processing)
mkdir -p ~/supernote-spike/storage
nix shell nixpkgs#python313 nixpkgs#uv -c uv venv --python "$(command -v python3.13)" ~/supernote-spike/.venv
nix shell nixpkgs#python313 nixpkgs#uv -c uv pip install --python ~/supernote-spike/.venv/bin/python "supernote[server]"
export LD_LIBRARY_PATH="$(nix eval --raw nixpkgs#stdenv.cc.cc.lib)/lib:$(nix eval --raw nixpkgs#zlib)/lib"
export SUPERNOTE_STORAGE_DIR=~/supernote-spike/storage
~/supernote-spike/.venv/bin/supernote serve --config-dir ~/supernote-spike/config &   # binds 0.0.0.0:8080 + :8081
~/supernote-spike/.venv/bin/supernote admin --url http://localhost:8080 user add nomad@spike.local --password spikepass1

# on rk1b — WebDAV (books-out)
printf 'address: 0.0.0.0\nport: 8082\ntls: false\ndirectory: %s/webdav-lib\npermissions: CRUD\nusers:\n  - username: nomad\n    password: spikepass1\n' "$HOME/supernote-spike" > ~/supernote-spike/webdav.yaml
nix run nixpkgs#webdav -- -c ~/supernote-spike/webdav.yaml &   # binds 0.0.0.0:8082

# open the LAN interface for each port (runtime, throwaway)
sudo iptables -I nixos-fw 1 -i end0 -p tcp --dport 8080 -j nixos-fw-accept
sudo iptables -I nixos-fw 1 -i end0 -p tcp --dport 8082 -j nixos-fw-accept
```

Device: Private Cloud → `http://192.168.1.23:8080` (annotations-back);
NetVirtualDisk → HTTP `192.168.1.23:8082` `/` (books-out).
