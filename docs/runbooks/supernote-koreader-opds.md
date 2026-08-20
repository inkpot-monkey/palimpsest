# Runbook: set the Nomad up as an OPDS reader (KOReader + Tailscale)

How the Supernote Nomad is configured to read the document library. This is the **device half**
of ADR-0031's books-out leg: Stump serves an OPDS 1.2 catalog (palimpsest#113/#114), a sideloaded
KOReader pulls from it (palimpsest#115), and reading position syncs back (palimpsest#116).
Nothing here is managed by Nix — the device is not a fleet host — so this file is the record.
Follow it to rebuild the setup after a factory reset.

Design: ADR-0031, especially the 2026-08-16 (Basic auth), 2026-08-17 (Tailscale) and 2026-08-19
(progress sync) revisions.

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
            ["username"]   = "thomas",
            ["password"]   = "<sops: profiles/library.yaml → stump/readers/thomas/password>",
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

## 5. Reading-progress sync

Where you are in a book is kept on the server, so position follows the book rather than the
device. Stump implements KOReader's sync protocol itself — this is configuration on both ends,
not a bridge (palimpsest#116, ADR-0031).

**The URL is a sops value, not something the server hands you.** It is
`https://library.palebluebytes.space/koreader/<key>`, where `<key>` is
`stump/readers/<you>/koreader_key` in the `library` secret file. Nothing is minted and nothing has
to be read back off rk1b: the provisioner *imposes* that key on Stump. If it could not, the
`stump-provision` unit is red and says which reader and why.

Unlike the catalog, this one goes **through the edge**, not direct to rk1b. Sync payloads are a
few hundred bytes each, so the VPS round-trip costs nothing measurable, and in exchange the
credential travels under TLS with a stable name. (Both work; the direct form is
`http://rk1b.tail8596c.ts.net:10001/koreader/<key>`.)

### On the device

The menu only exists with a book open — the plugin is `is_doc_only`, so you will not find it from
the file browser. Open a book, tap the top of the screen, then: ***Tools* (wrench tab) → Progress
sync**.

1. **Custom sync server** → paste the URL above, exactly as printed. It ends at the key; KOReader
   appends `/users/auth` and `/syncs/progress` itself.
1. **Register / Login** → enter **anything** — `x` / `x` will do. This step feels wrong and is
   required: KOReader will not sync until it believes it has logged in, and Stump does not
   validate the credentials at all (the key in the URL is the real credential). It sends an MD5 of
   whatever you type; Stump ignores it.
1. **Document matching method** → **Binary**. Stump matches books by content hash and has no
   filename fallback, so a reader set to *Filename* will push progress that matches nothing. This
   is KOReader's default on current builds, but it is per-install state that a migration can move,
   so set it explicitly.
1. Optionally turn on **auto-sync**; otherwise position is pushed on document close and on the
   *Push progress* menu item.

Written to `/sdcard/koreader/settings/kosync.lua`. The plugin's full key set, from its own
`default_settings` table upstream — the first five are the ones this setup depends on, the rest
are listed so a hand-edited file is not silently missing something the menu would have written:

```lua
return {
    ["settings"] = {
        ["custom_server"]       = "https://library.palebluebytes.space/koreader/<key>",
        ["checksum_method"]     = 0,     -- 0 = BINARY, 1 = FILENAME. Must be 0 (see above).
        ["username"]            = "x",   -- not validated by Stump
        ["userkey"]             = "<md5 of whatever you typed>",
        ["auto_sync"]           = true,  -- push on close; otherwise use "Push progress"
        ["sync_forward"]        = 1,     -- 1 = PROMPT, 2 = SILENT, 3 = DISABLE
        ["sync_backward"]       = 3,     -- same scale; DISABLE avoids being dragged backwards
        ["pages_before_update"] = nil,   -- integer > 0: push mid-read every N pages
        ["send_metadata"]       = true,
        ["kosync_hostname"]     = nil,   -- device name reported to the server
    },
}
```

`sync_forward` / `sync_backward` are the ones worth understanding, because they govern the PULL
and their absence is not neutral — the plugin falls back to its defaults, and "why did my device
not move to where the other one got to" is decided here. FORWARD is the normal case (the server is
ahead of this device); BACKWARD is the server being behind, which usually means another device is
mid-read further back and you do not want to be yanked to it.

Writing this file by hand is enough on its own — **verified 2026-08-20**: pushing exactly the
first five keys over `adb` and force-stopping KOReader first produced a working round-trip with no
in-app configuration at all. `adb push … /sdcard/koreader/settings/kosync.lua`, then re-launch.

As with `settings.reader.lua`, **force-stop KOReader before editing this by hand** — it rewrites
the file on exit.

### The web reader will not resume where the device left off

Expected, and not a misconfiguration: **progress crosses as a percentage, but the position only
crosses in one direction.**

Stump stores a position as an *epubcfi* or a page number. KOReader pushes an *x-pointer*
(`/body/DocFragment[17]/body/div.0`). Upstream's handler
(`apps/server/src/routers/koreader/sync.rs`, `parse_progress`) accepts `epubcfi(…)` or an integer
and treats everything else as an x-pointer it cannot use — its own comment says *"Stump does not
support x-pointers"*. That arm stores nothing but the percentage, logging at `debug`.

So after a push from the Nomad:

```
percentageCompleted  0.8356     <- stored, and shown in the UI
epubcfi              null       <- nothing to derive it from
```

and clicking **Read** in the web UI opens at the beginning, because there is no location to
restore. The 83% on the card is a number, not a place.

The asymmetry is one-directional and each leg has been confirmed on hardware (2026-08-20):

| Direction | Position | Percentage |
|---|---|---|
| Nomad → Nomad | ✅ x-pointer round-trips intact | ✅ |
| Nomad → web reader | ❌ dropped | ✅ shown |
| web reader → Nomad | ✅ Stump writes a real epubcfi, KOReader accepts it | ✅ |

A push from the device also CLEARS any `epubcfi` the web reader had written, so the two readers
take turns rather than coexisting. Nothing to fix here: translating x-pointers to epubcfi is
upstream work the code comment already contemplates and declines.

### Verify

Open a book, turn a few pages, close it. Then on rk1b:

```bash
# The device's own view — this is the fetch route, and it is what "position round-trips" means.
curl -s "http://127.0.0.1:10001/koreader/<your key>/syncs/progress/<book hash>" | jq
# → {"document":"…","progress":"42","percentage":0.42,"device":"…"}
```

The book hash is Stump's `koreaderHash` for that book. If a push 404s, the book has no hash: see
*Books with no hash* below.

### Whose progress it is

Your own. The device syncs as **your reader account** — the same one you log into the web UI with
— so what you read on the Nomad is what you see in the browser.

Note which account that is *not*. `stump/user` is the **server owner**: it exists to bootstrap and
administer the catalog, the provisioner is the only thing that uses it, and you should not log in
with it. That is not fussiness. Stump's `enforce_permissions` returns OK unconditionally for the
owner, and an API key is accepted as a bearer token on every route — so an owner's sync key would
be a full administrative credential sitting in a plaintext Lua file on the tablet, no matter what
scope it recorded. Readers are non-owner accounts precisely so that the key on the device is
worth exactly one thing.

Adding someone else is another entry under `stump.readers` in the secret file and a redeploy:
their own account, their own password, their own key, their own progress.

### Books with no hash

Stump only generates KOReader hashes for **PDF and EPUB** — upstream's zip/rar processors have
the call commented out, so comics can never sync. Beyond that, a book indexed before the library
had `KoReader-compatible hashes` turned on has no hash and answers 404 to the device's push.
`stump-provision` detects that and enqueues a hash-regenerating rescan on every deploy, so the
fix is usually just `systemctl restart stump-provision`. It names the books it is scanning for —
the same names on run after run mean a file the hasher cannot read at all, which no further
scanning will fix. If it instead warns that a *library* does not generate hashes, turn the setting
on in that library's settings page first — the provisioner will not rewrite a library config,
because doing so replaces the whole config and would erase hand curation.

### One book that never syncs while the rest do

If a book *has* a `koreaderHash` and still 404s, suspect the hash itself. KOReader samples 1 KiB
at offsets 0, 1 KiB, 4 KiB, 16 KiB, 64 KiB … and stops past EOF; where that last sample straddles
the end of the file, KOReader hashes the bytes it got while Stump hashes a zero-padded 1 KiB
buffer, so the two disagree. It only bites files whose size lands just above a sample offset, and
there is nothing to configure — the device is right and the server is wrong. Confirm by computing
`util.partialMD5` over the file yourself and comparing with Stump's `koreaderHash`; if they
differ, that is this, and it wants an upstream fix rather than a local one.

### Choosing a key

Both of a reader's credentials are declared, so there is nothing to bank and no second deploy.
Generate a key like this and paste it into the secret file:

```bash
printf '%s_%s_%s\n' stump "$(openssl rand -hex 8)" "$(openssl rand -hex 24)"
```

Both the three `_`-delimited parts and the `stump` prefix are required, for different reasons —
the sync route needs the shape, and the prefix is what lets the provisioner verify the key's
resolved scope. `modules/nixos/profiles/stump.nix` explains which is which; don't trim either.

```yaml
# the `library` sops file
stump:
  user: catalog-owner
  password: <administrative; not for daily use>
  readers:
    thomas:
      password: <your OPDS + web UI password>
      koreader_key: stump_9f3a1c7e_4b6d2a...
```

Commit + push the secrets repo, `nix flake update secrets`, redeploy.

Because the key is declared rather than minted, **rebuilding the catalog database does not break
the device.** The Stump DB is a cache of the corpus; wipe it and the next `stump-provision` run
recreates the account and re-imposes the same key from sops. Reading *progress* does not survive
that — it lived in the database — but nothing has to be re-typed on the Nomad.

## 6. Verify the catalog

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

## 7. The pen in sideloaded apps — measured 2026-08-18

ADR-0031's split of responsibilities (handwriting stays with the stock apps, reading moves to a
sideloaded reader) rested on an assumption that was reasoned but never measured, and
palimpsest#115 is the ticket that settled it. The answer is sharper than the assumption.

**The pen is fully available to sideloaded apps.** It is a dedicated Wacom EMR digitiser on its
own input device, separate from the two touchscreens, and Android exposes it as a first-class
stylus:

```console
$ adb shell getevent -pl
add device 1: /dev/input/event7
  name:     "Wacom-pen"
    BTN_DIGI  BTN_TOOL_RUBBER  BTN_TOUCH  BTN_STYLUS  BTN_STYLUS2
    ABS_PRESSURE : min 0, max 4095        # 12-bit; the touchscreens report 0-255
    ABS_TILT_X   : min -9000, max 9000
    ABS_TILT_Y   : min -9000, max 9000

$ adb shell dumpsys input | grep -A6 Wacom-pen
    Sources: 0x00005002                   # SOURCE_STYLUS | SOURCE_TOUCHSCREEN
```

So a sideloaded app receives `TOOL_TYPE_STYLUS` MotionEvents carrying pressure, tilt, both barrel
buttons and the eraser end. Nothing is withheld from it.

**What is *not* available is Ratta's handwriting engine and the `.note`/`.mark` formats.** Those
are written only by the stock Note and Document apps. This is the real constraint, and it is a
format/engine boundary rather than an input one.

**In KOReader specifically, the pen behaves exactly like a finger.** That is KOReader's doing,
not the platform's: it is a reader with no ink surface, so it consumes position only and ignores
the stylus axes. Confirmed on device 2026-08-18, alongside `["highlights"] = 0` in the `.sdr`
sidecars.

**Why this matters for future work.** The original phrasing — a sideloaded reader "gets ordinary
Android stylus input, not the Supernote pen layer" — reads as though the pen is degraded outside
the stock apps. It is not. A future sideloaded annotation app *could* offer genuine
pressure-sensitive ink; what it could never do is produce a Supernote-native notebook. Do not
rule out a sideloaded pen feature on the belief that the digitiser is unavailable.

## Known limits

- **No e-ink driver.** KOReader has no EPD support for the A6X2
  (`koreader/android-luajit-launcher#499`, open), so it renders as an ordinary Android app:
  ghosting, no partial-refresh control, no per-mode tuning. The device's own rotation sensor does
  not drive it either. It is usable, not the KOReader experience you would get on a Kobo.
- **Freezes** have been reported on long reading sessions (`koreader/koreader#12669`).
- **The pen works, but KOReader does nothing with it** — see section 7. Not a limit of the
  device or of sideloading; a limit of KOReader.
- **Nothing here is declarative.** A factory reset loses all of it; this file is the recovery
  procedure.
