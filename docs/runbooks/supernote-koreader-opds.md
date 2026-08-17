# Runbook: set the Nomad up as an OPDS reader (KOReader + Tailscale)

How the Supernote Nomad is configured to read the document library. This is the **device half**
of ADR-0031's books-out leg: Stump serves an OPDS 1.2 catalog (palimpsest#113/#114), and a
sideloaded KOReader pulls from it. Nothing here is managed by Nix — the device is not a fleet
host — so this file is the record. Follow it to rebuild the setup after a factory reset.

Design: ADR-0031, especially the 2026-08-16 (Basic auth) and 2026-08-17 (Tailscale) revisions.

## What the device is

- Supernote Nomad (A6 X2), `SN078D10010247`, Chauvet `E103.2606141001.2389`, Android 11,
  **arm64-v8a**.
- Tailnet node `supernote-nomad`.

## 1. Enable sideloading — this is also what exposes ADB

*Settings → Security & Privacy → Sideloading → On*, accept the disclaimer.

That single toggle gates both tap-to-install *and* ADB. With it off the device enumerates USB as
config `mtp` with only MTP + HID-keyboard interfaces and no ADB interface (class 255, subclass
66), so `adb devices` is empty while `lsusb` still shows `2207:0007 … Supernote Nomad`. If ADB
sees nothing, check this toggle before suspecting the cable.

Accept the on-device *"Allow USB debugging?"* prompt when it appears.

## 2. Tailscale

The device gets its own client — it is a first-class tailnet node, not reached through a subnet
router. Chauvet's AOSP VPN stack is intact (`/dev/tun`, `com.android.vpndialogs`,
`BIND_VPN_SERVICE`).

```bash
# The UNIVERSAL apk — the device has no Play services, so the Play build is not an option.
curl -LO https://pkgs.tailscale.com/stable/tailscale-android-universal-<version>.apk
adb install tailscale-android-universal-<version>.apk
```

Log in on the device. The login redirect works despite no Custom Tabs service being registered.

Then **two settings that are not optional**:

```bash
# Without this the tunnel comes up and then silently drops on sleep, which presents as an
# intermittent catalog rather than as a VPN fault. The `user,` list persists across reboots.
adb shell dumpsys deviceidle whitelist +com.tailscale.ipn
```

*Settings → VPN → (gear next to Tailscale) → Always-on VPN → **on***, so the tunnel returns after
a reboot. Chauvet does not surface that screen; reach it with:

```bash
adb shell am start -n 'com.android.settings/.Settings$VpnSettingsActivity'
```

- **Leave "Block connections without VPN" (lockdown) OFF.** If the tunnel fails to come up with
  lockdown on, the device has no network at all — including no way to reach a login page — and is
  recoverable only over ADB.
- Toggle always-on in the UI, never by writing `settings put secure always_on_vpn_app`. The real
  work is in `VpnManager.setAlwaysOnPackage()`; writing the value alone leaves the system
  believing always-on is active with nothing enforcing it.
- **Disable key expiry for this node** in the Tailscale admin console. Otherwise the node key
  lapses (180 days by default), the device drops off the tailnet silently months later, and
  recovery means driving a browser login on e-ink.

Verify from the device:

```bash
adb shell ping -c 3 rk1b.tail8596c.ts.net     # 0% loss
adb shell nc -w 4 100.94.98.119 10001 </dev/null && echo OPEN   # Stump's OPDS port
```

## 3. KOReader

```bash
# arm64 — the device is arm64-v8a. Releases: github.com/koreader/koreader/releases
adb install koreader-android-arm64-v<version>.apk
```

**It will not start without "All files access."** KOReader declares
`MANAGE_EXTERNAL_STORAGE` and no other storage permission, and has no SAF fallback — it ships its
own file browser rather than using the system picker. That permission is app-wide by design;
there is no per-folder variant. Grant it.

### The library folder — deliberately NOT under `Document/`

Set the home folder to **`/sdcard/opds`**, a new top-level folder, and lock it:

*File browser → ☰ → Settings → Home folder settings → Set home folder → **Lock home folder***

`Document/` is the tree Private Cloud syncs. Anything KOReader touches there — downloaded books
*and* the `<book>.sdr/` sidecar it writes beside every file it opens — would be uploaded into the
Supernote store, duplicating library content the reconciler already owns. A top-level folder
sidesteps that entirely rather than relying on ignore rules.

The cost, accepted knowingly: the **native** Supernote reader cannot open these files (it browses
`Document/`), and they get no device-side backup. rk1b is the source of truth; anything here can
be re-pulled from the catalog.

The home-folder lock is a *UI* confinement, not a sandbox — the app still holds all-files access.

### Settings that matter

Written to `/sdcard/koreader/settings.reader.lua`:

```lua
["home_dir"]         = "/storage/emulated/0/opds"
["download_dir"]     = "/storage/emulated/0/opds"   -- else downloads fall back to `lastdir`
["lastdir"]          = "/storage/emulated/0/opds"
["lock_home_folder"] = true
```

`download_dir` is the easy one to miss: unset, it falls back to `lastdir`, which on a fresh
install is KOReader's bundled `koreader/help` folder — so the first book lands inside the app
directory, outside the locked home, where you will not see it.

To edit these by hand, **force-stop KOReader first** (`adb shell am force-stop org.koreader.launcher`) — it rewrites the file on exit and will clobber the edit. Validate before
pushing; a syntax error yields a KOReader that silently starts with default settings:

```bash
lua -e 'assert(loadfile("settings.reader.lua"))()'
```

## 4. The OPDS catalog

Stored separately, in `/sdcard/koreader/settings/opds.lua`:

```lua
return {
    ["servers"] = {
        {
            ["title"]      = "Palimpsest Library",
            ["url"]        = "http://rk1b.tail8596c.ts.net:10001/opds/v1.2/catalog",
            ["username"]   = "opds",
            ["password"]   = "<sops: profiles/library.yaml → stump/opds_password>",
            ["searchable"] = false,
        },
    },
}
```

Writing this file **replaces** KOReader's built-in default catalogs (Gutenberg, Standard Ebooks).

In the UI it lives under **Search (magnifier) → OPDS catalog**, at the bottom — *not* under Tools,
which is the natural guess. Long-press an entry to edit it; tapping connects.

### Why it points at rk1b and not at `library.<domain>`

The `library` vhost is served by **kelpy, a VPS**. Pulling through it means a book stored on rk1b
— in the same room as the device — leaves the house and comes back, gated by home *upstream*
bandwidth. Measured: a 23 MB epub crawled through the edge; the direct path is a LAN transfer,
with rk1b reporting the peer as `active; direct 192.168.1.x`.

Direct is also not a home-only convenience: both ends are tailnet nodes, so it works away from
home too. The edge's remaining value for this client is TLS and a pretty name.

Plain HTTP is acceptable here because the traffic is inside WireGuard and port 10001 is opened on
`tailscale0` only (never `openFirewall`). Stump accepts **Basic auth on OPDS 1.2 and nowhere
else**, so the password cannot be replayed against the GraphQL API.

The browser path (`https://library.<domain>`) is unchanged and still goes through the edge — so
`parts/settings.nix`'s `library` entry describes the *browser's* delivery path, not this one.

## 5. Verify

```bash
# From a tailnet host — 401 with a challenge means the endpoint is live and gated.
curl -sI https://library.palebluebytes.space/opds/v1.2/catalog | grep -i www-authenticate
# → WWW-Authenticate: Basic realm="stump OPDS v1.2"
```

On the device: *Search → OPDS catalog → Palimpsest Library*. The root feed serves six navigation
entries (*Keep reading, All series, All libraries, All books, …*) **regardless of whether the
library has any content**, so seeing that list proves Basic auth works but says nothing about the
corpus. Drill into *All books* to see the corpus.

Download one and confirm it landed:

```bash
adb shell ls -la /sdcard/opds/
adb shell md5sum "/sdcard/opds/<file>.epub"   # compare against the source
```

Proven end-to-end 2026-08-17: a 23 MB epub pulled into `/sdcard/opds` with an MD5 identical to
the source file.

## Known limits

- **No e-ink driver.** KOReader has no EPD support for the A6X2
  (`koreader/android-luajit-launcher#499`, open), so it renders as an ordinary Android app:
  ghosting, no partial-refresh control, no per-mode tuning. The device's own rotation sensor does
  not drive it either. It is usable, not the KOReader experience you would get on a Kobo.
- **Freezes** have been reported on long reading sessions (`koreader/koreader#12669`).
- **Nothing here is declarative.** A factory reset loses all of it; this file is the recovery
  procedure.
