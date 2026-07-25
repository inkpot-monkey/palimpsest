# Supernote Nomad (A6 X2) — Self-Hosted File Transport Options

## The question

We want a **fully self-hosted** book/document library that round-trips **books OUT** to a
Supernote Nomad (A6 X2) and pulls **handwritten annotations BACK** to our own server. This
document surveys the realistic transport mechanisms the device supports on **current-generation
"Chauvet" firmware** and rates each against our hard constraints.

## Hard constraints

- **No Supernote Cloud, no Dropbox, no Google Drive.** Transport must terminate on our own infra.
- **The device cannot run a Tailscale client.** It is a locked-down Android tablet; there is no way
  to install the Tailscale app. Any tailnet reachability must be provided *around* the device.

## Confirmed device / firmware

- **Device:** Supernote Nomad = the **A6 X2** (X2 generation, alongside the A5 X2 "Manta"). The Nomad
  is covered by the **"Manta & Nomad" changelog**, not the older "A5 X / A6 X" (X-series) changelog.
  [1]
- **Firmware line:** "Chauvet" is Supernote's OS/firmware family. The relevant self-hosting features
  landed in **Chauvet 3.25.39, released 2025-11-14** (beta **3.24.39_beta**, 2025-10-29). Older
  X-series devices got the analogous **2.23** build. [1][3][4]

> To confirm what a specific unit is running: **Settings → About → firmware version**. Anything
> **≥ 3.25.39** has the WebDAV + Private Cloud stack described below; below that, only Browse &
> Access + USB exist.

______________________________________________________________________

## Options table

| Mechanism | Direction | Locality | Auth | Maturity | Self-hosted-pure? |
|---|---|---|---|---|---|
| **NetVirtualDisk / ServerLink (native WebDAV)** | Both, but **manual** (download to read, long-press to upload back) | Any WebDAV URL reachable from device (LAN, Tailscale-served, or edge) | HTTP or HTTPS; host + optional port; username + **app password** | Shipped 3.25.39 (Nov 2025), young | **Pass** — points at your own server |
| **Private Cloud (native protocol)** | **Both, automatic two-way `.note` sync incl. annotations** | Any reachable server; **Linux host required** | Per Supernote deployment manual | Shipped 3.25.39, young, IT-heavy setup | **Pass** — your own server |
| **allenporter/supernote (self-hosted Private Cloud server)** | **Both, automatic two-way `.note` sync** | Any reachable server (LAN / Tailscale / edge) | App-defined | Active OSS, v0.16.0 (Jul 2026), Docker, Apache-2.0 | **Pass** |
| **Browse & Access (built-in LAN web server)** | Both, **manual** (browser upload + download); server-scriptable **pull** | **LAN only** (device IP:port on same Wi-Fi) | None documented | Long-standing, stable | **Pass** |
| **snbackup (community CLI over Browse & Access)** | **Pull only** (`.note` backup) | LAN only | None | Active OSS, v1.3.x | **Pass** |
| **USB (MTP)** | Both, manual | Cable | Device unlock | Always-worked floor | **Pass** |

______________________________________________________________________

## Per-mechanism detail

### 1. NetVirtualDisk / ServerLink — the native WebDAV client

**This is the headline feature and the answer to "does the Nomad do WebDAV today": yes, but read
carefully what kind of WebDAV.**

- Added as the **ServerLink app** (since renamed **NetVirtualDisk**) in **Chauvet 3.25.39
  (2025-11-14)**; installed on demand from **Settings → Apps / Supernote App Store**. It "speaks
  WebDAV, the open standard, for direct connection to your existing NAS or self-hosted server." [1][2][6]
- **It is a *mounted network drive*, not an auto-sync.** Multiple independent hands-on sources
  describe the same behaviour: the WebDAV target appears as a drive in the device File Browser;
  **tapping a file downloads it onto the Supernote to read/annotate**, and a **long-press** menu lets
  you "rename, copy, move, **upload (to WebDAV)**, delete, or password-lock a file." eWritable's 3.25
  writeup states it plainly: it "functions as a mounted network drive supporting manual file browsing
  and downloading … **rather than automatic two-way synchronization**." [3][5]
- **Round-trip of annotations is therefore MANUAL and per-file** — you must long-press each annotated
  `.note`/export and choose Upload. There is **no evidence** the device watches your Note folder and
  auto-pushes edited notebooks back over WebDAV.
- **Auth / transport** (from Supernote's Nextcloud setup guide): choose **HTTP or HTTPS** (HTTPS
  recommended; HTTP "supported for unencrypted or internal networks"); enter **host only**
  (`cloud.example.com` or IP); **port** blank → 443/80 default, or custom; **path** e.g.
  `/remote.php/dav/files/USERNAME/`; **username + App Password** (not the main account password). [7]
- **Self-signed certificate tolerance: UNCONFIRMED.** The setup docs neither promise nor deny it.
  This matters if we terminate TLS ourselves without a public CA. *Would confirm by:* pointing
  NetVirtualDisk at a self-signed HTTPS WebDAV endpoint and observing whether it connects, or by
  running plain HTTP over a trusted LAN/Tailscale path (HTTP is explicitly supported).
- **Folder coverage** (Document / Note / EXPORT / INBOX / MyStyle): **UNCONFIRMED from primary
  sources.** The drive is a *remote* mount you browse; it is not documented as mirroring specific
  on-device folders. *Would confirm by:* inspecting the app on-device.
- **Real-world complaints:** early reports note the device gets "confused by a lot of files" and at
  least one case of a drawing appearing twice — consistent with an immature v1 mount. \[Reddit/Mastodon
  chatter, secondary — see 8.\]

### 2. Private Cloud — the native protocol (the real two-way sync)

- Also shipped in **3.25.39 (2025-11-14)**: Supernote **packaged their own cloud backend** for you to
  self-host, giving "full data sovereignty." Reached via **Settings → Security & Privacy** (and the
  device's **Sync → Private Cloud** binding). [1][2]
- **This is the genuine automatic two-way sync path** — the same protocol the Supernote Cloud uses,
  so it syncs `.note` files *including handwritten annotations* in both directions, not a manual mount.
- **Cost:** "Some IT knowledge and steps are required"; the official deployment **requires a Linux
  host** and following Supernote's deployment manual (hardware, server, firewall). [2][3]
- This is the architecturally-correct answer to "auto round-trip annotations," but the official server
  is heavier to stand up than WebDAV.

### 3. allenporter/supernote — self-hosted Private Cloud, community implementation

- An **independent open-source reimplementation of the Supernote Private Cloud protocol** — a
  self-hosted sync server the device talks to via **Settings → Sync → Private Cloud**. [9]
- Claims **"100% of the community Supernote OpenAPI Specification"**; the device performs **two-way
  `.note` synchronization** and **uploads `.note` files using the official Private Cloud protocol**.
- **Python / asyncio / SQLite**, Docker-supported, **Apache-2.0**, **v0.16.0 (July 2026)**, ~716
  commits, 43 releases — actively maintained. **No Supernote Cloud dependency.** [9]
- Bonus: it locally parses notebooks for optional transcription/indexing — useful for a document
  library, but not required for transport.

### 4. Browse & Access — the LAN web-server floor

- Built-in feature that turns the device into a **small web server on the local Wi-Fi**; you open a
  **URL (device IP:port) in a browser** on another machine on the **same network**. [10]
- **Both directions, manually:** an **Upload** button pushes files to the device; **single-clicking**
  a file downloads it. **LAN-only** — Supernote and the other device "must be connected to the same
  Wi-Fi." A **popup on the Supernote must be OK'd**, and the feature must be toggled/active on-device
  (screen interaction required to start it). [10]
- **It is a real, scriptable HTTP endpoint, not just a manual UI** — proven by snbackup (below) driving
  it programmatically to enumerate and pull `.note` files. That makes it viable as a **server-driven
  return leg**: a script on our infra can *pull* annotated notes from the device's IP:port.
- Exposes the device's `.note` files as stored on disk (snbackup retrieves them verbatim). [11]

### 5. snbackup — community CLI over Browse & Access

- Python CLI (`pip install snbackup`, **github.com/theburningbush/snbackup**, v1.3.x, active) that
  **downloads `.note` files** from the device **via Browse & Access**; **no account, no cloud, no app**.
  Config `config.json` sets `save_dir` + `device_url` (the device's Browse & Access URL). [11]
- **Pull/backup only** — it does not upload or restore to the device. Incremental after first full run.
- Useful as the **automated "annotations BACK" leg** on the LAN, but only fetches `.note` (not a
  general two-way sync).

### 6. USB (MTP) — the reliability floor

- Cable transfer works with no network at all; the device presents storage over **MTP** when connected
  and unlocked. Manual, both directions. This is the always-available fallback if every network path
  fails, but it is not scriptable into an unattended round-trip and is out-of-band for a headless server.

______________________________________________________________________

## Tailscale reachability (device can't run Tailscale)

Because the tablet can't join the tailnet directly, reachability must be provided by something else on
its network. Three general approaches (Tailscale/GL.iNet facts, not Supernote-specific):

**(a) Subnet router advertising the home LAN.** Run Tailscale on a home box (`--advertise-routes` +
IP forwarding); tailnet devices then reach non-Tailscale devices on that subnet, "including resources
where Tailscale cannot be installed." [12] Conversely, when the Supernote is on **home Wi-Fi**, it
reaches tailnet **service IPs** via that router. **Tradeoffs:** simplest; **works only while the device
is home**; watch routing conflicts if a LAN host also runs Tailscale (client drops packets with
unexpected source IPs / SNAT quirks). [12][13]

**(b) GL.iNet travel router running Tailscale.** A GL.iNet router joins the tailnet itself; **every
device on the router's Wi-Fi reaches the tailnet with no per-device client** — explicitly "whether or
not Tailscale is installed on all connected devices." [14] **Tradeoffs:** works **anywhere** the router
has internet (hotel, etc.); the device just joins the router's SSID; extra hardware; GL.iNet's Tailscale
build is not maintained by Tailscale and still carries a **beta** flag (fw 1.8.4). [14]

**(c) Avoiding a public Caddy edge.** Exposing WebDAV/Private-Cloud at a **public Caddy edge is
avoidable**: (a) covers the at-home case and (b) covers travel, so the endpoint can stay tailnet-only
and never face the public internet. Prefer this — it keeps the WebDAV/sync surface off the public web.
An edge exposure is only needed if we want the device to sync from arbitrary networks with *neither* a
subnet router nor a travel router in play.

______________________________________________________________________

## Recommended shortlist

1. **allenporter/supernote (self-hosted Private Cloud) reached over Tailscale.** This is the only
   option that gives **automatic, bidirectional `.note` sync including annotations** while staying fully
   self-hosted and actively maintained. Front it with a Tailscale subnet router at home (approach a) and
   a GL.iNet travel router for away (approach b); no public edge. **Primary candidate for the round-trip.**

1. **Native WebDAV (NetVirtualDisk) → our own WebDAV server, over Tailscale/LAN.** Lowest-effort to
   stand up and officially supported, but the **return leg is manual per-file upload**. Good for the
   **books-OUT** direction (browse library, download to read) and acceptable for annotations-back **if**
   we accept manual "long-press → Upload." Pair with (a)/(b) for reachability; HTTP is fine on a trusted
   tailnet path, sidestepping the self-signed-cert unknown.

1. **Browse & Access + snbackup as the automated LAN return leg** (floor / belt-and-suspenders). A
   server-side pull of annotated `.note` files whenever the device is on home Wi-Fi — no device-side
   config, no cloud. Combine with (1) or (2) rather than relying on it alone.

______________________________________________________________________

## ⚠️ RISK CALLOUT — native WebDAV does **not** auto-round-trip annotations

**The native WebDAV client (NetVirtualDisk/ServerLink) is a *manually-driven mounted network drive*,
not a two-way sync.** It downloads files to read/annotate and requires an explicit **long-press →
Upload** to send an annotated file back — per file, by hand. Multiple hands-on sources confirm it is
**"rather than automatic two-way synchronization."** [3][5]

**Consequence for the architecture:** if the transport design assumed "point WebDAV at our server and
annotations sync themselves back," **that assumption is wrong and the return-leg destination must be
renegotiated.** Concretely:

- The **only self-hosted path that auto-returns annotations** is the **Private Cloud protocol** — either
  Supernote's official Linux server or **allenporter/supernote** (shortlist #1). If we want hands-off
  round-trip, the destination should be a **Private Cloud server, not a WebDAV share.**
- If we stay on WebDAV, the **named fallbacks for the return leg** are: **(i)** accept manual
  NetVirtualDisk uploads; **(ii)** have the server **pull** annotated `.note` files over **Browse &
  Access** (snbackup) while the device is on the LAN; or **(iii)** **USB/MTP** as the offline floor.

**Also unconfirmed (do not overstate):** self-signed-cert tolerance of the WebDAV client, and exactly
which on-device folders (Document/Note/EXPORT/INBOX/MyStyle) it maps. Both are checkable only on a
device running ≥ 3.25.39.

______________________________________________________________________

## Sources

1. Supernote — Manta & Nomad changelog: https://support.supernote.com/change-log/changelog-for-manta-and-nomad
1. Supernote official blog — Private Cloud for Data Sovereignty & NetVirtualDisk (formerly ServerLink) for Remote Files Control via WebDAV: https://supernote.com/blogs/supernote-blog/private-cloud-for-data-sovereignty-serverlink-for-remote-files-control-via-webdav
1. eWritable — Supernote Firmware Version 3.25: https://ewritable.net/brands/ratta-supernote/firmware/3-25/
1. eWritable — New Supernote Beta Firmware Includes Support for WebDAV & Private Servers: https://ewritable.net/new-supernote-beta-firmware-includes-support-for-webdav-private-servers/
1. eWritable / hands-on descriptions of NetVirtualDisk drive behaviour (browse, tap-to-download, long-press upload/move/delete): https://ewritable.net/new-supernote-beta-firmware-includes-support-for-webdav-private-servers/
1. Supernote — Manta & Nomad Beta changelog: https://support.supernote.com/change-log/changelog-for-the-beta-versions-of-manta-and-nomad
1. Supernote — Setting Up Your Nextcloud (WebDAV) Account in the NetVirtualDisk (formerly ServerLink) App: https://support.supernote.com/setting-up-your-nextcloud-webdav-account-in-the-serverlink-app
1. User report (Mastodon, Supernote WebDAV/Nextcloud, "confused by a lot of files / drawing twice"): https://mastodon.social/@ctietze/115558822831016346
1. allenporter/supernote — self-hosted Private Cloud server / PKM hub (Apache-2.0, v0.16.0, Jul 2026): https://github.com/allenporter/supernote
1. Supernote — Browse & Access (Wi-Fi transfer): https://support.supernote.com/en_US/Tools-Features/wi-fi-transfer
1. snbackup — community CLI backing up `.note` over Browse & Access: https://github.com/theburningbush/snbackup and https://pypi.org/project/snbackup/
1. Tailscale Docs — Subnet routers: https://tailscale.com/docs/features/subnet-routers
1. Tailscale Docs — Configure a subnet router: https://tailscale.com/docs/features/subnet-routers/how-to/setup
1. Tailscale blog — GL.iNet Beryl AX travel router + Tailscale (all connected devices reach the tailnet): https://tailscale.com/blog/tailscale-glinet-travel-router-mt3000-beryl-ax ; GL.iNet Docs — Tailscale: https://docs.gl-inet.com/router/en/4/interface_guide/tailscale/
