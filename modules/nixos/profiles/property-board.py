#!/usr/bin/env python3
"""The property board: map, favourites, price history (property#5).

The reading surface over the database the property-watch job writes. The job
wakes at 07:30, sweeps the market and speaks into a room; it has no UI and
nowhere to receive a click. This is where you look at the result on a map and
mark what you like.

ONE WRITER PER TABLE. The job owns `listings`, `observations` and `sweeps`;
this process owns `favourites` and nothing else. That is the entire contract
between the two halves, it is why the schema looks the way it does, and it is
why this file has exactly two statements that are not SELECTs.

Standard library only, for the same reason the job is: it runs in an
environment with almost no packages, and sqlite3 and http.server are both in
the box. The one thing fetched from outside is Leaflet, in the browser -- see
the note above PAGE.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import stat
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# How long a writer waits for the other process's transaction before giving up.
# The job's writes are small and batched, so a few seconds is generous; the
# point is that the loser of a race waits rather than erroring, because the
# error surfaces as a failed click with no explanation.
BUSY_TIMEOUT_MS = 10_000

# The board's half of the schema, and all of it. Created here because the board
# may well be opened before the job's first sweep, and a missing table is a 500
# on the first click. Deliberately NOT the job's tables: if this file created
# `listings`, a column the job later added would be silently absent instead of
# loudly wrong, and the job would be filling a table it did not define.
FAVOURITES_SCHEMA = """
CREATE TABLE IF NOT EXISTS favourites (
  id TEXT PRIMARY KEY, added_on TEXT NOT NULL, note TEXT
);
"""


def _share(path: str) -> None:
    """Make `path` writable by the `property-watch` group, if it exists yet.

    sqlite creates its files under the process umask, which on this fleet is
    022 -- so the database and its `-wal`/`-shm` siblings land 0644 and the
    second of the two processes sharing them cannot write. The directory is
    setgid 2770 so the GROUP is already right; only the mode is wrong.

    Called on both halves: whichever process opens the file first fixes it, and
    the existing live database (created 0644 before this existed) is repaired on
    the next open rather than needing a one-off chmod that the next run undoes.
    """
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        return
    if not mode & stat.S_IWGRP:
        try:
            os.chmod(path, mode | stat.S_IWGRP | stat.S_IRGRP)
        except PermissionError:
            # Not ours to fix -- the other process owns it and will. Carrying on
            # is right: reads still work, and the first failing write says so.
            pass


def connect(path: str) -> sqlite3.Connection:
    """Open the shared database, with the hygiene two writers make necessary."""
    # New files inherit this, so `-wal` and `-shm` come out group-writable
    # without needing to be chased afterwards. A writer needs all three.
    os.umask(0o002)
    db = sqlite3.connect(path, timeout=BUSY_TIMEOUT_MS / 1000)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
    db.executescript(FAVOURITES_SCHEMA)
    for suffix in ("", "-wal", "-shm"):
        _share(path + suffix)
    return db


# --------------------------------------------------------------------------
# The read model
# --------------------------------------------------------------------------

# Only what the board shows. `raw` in particular is deliberately absent: it is
# the verbatim source record, it is large, and 275 of them would make the one
# request this page makes an order of magnitude heavier for nothing anyone
# looks at.
_COLUMNS = [
    "id", "outcode", "status", "first_seen", "last_seen",
    "first_price", "price", "bedrooms", "bathrooms",
    "title", "address", "kind", "tenure", "lease_years",
    "agent", "lat", "lon", "url", "score", "verdict",
]  # fmt: skip


def _row(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["favourite"] = bool(d.pop("fav_id", None))
    first, now = d.get("first_price"), d.get("price")
    d["price_drop"] = (first - now) if (first is not None and now is not None) else None
    d["mappable"] = d["lat"] is not None and d["lon"] is not None
    return d


def listings(db: sqlite3.Connection) -> list[dict]:
    cols = ", ".join("l." + c for c in _COLUMNS)
    rows = db.execute(
        f"""
        SELECT {cols},
               f.id AS fav_id, f.note AS note,
               -- Days on market runs first_seen -> last_seen, NOT first_seen ->
               -- today: a withdrawn listing's clock stopped when it withdrew,
               -- and counting to today would show it ageing forever.
               CAST(julianday(l.last_seen) - julianday(l.first_seen) AS INTEGER)
                 AS days_on_market
          FROM listings l
          LEFT JOIN favourites f ON f.id = l.id
         ORDER BY l.score IS NULL, l.score DESC, l.first_seen DESC
        """
    ).fetchall()
    return [_row(r) for r in rows]


def history(db: sqlite3.Connection, listing_id: str) -> list[dict]:
    """Price and status over time for one listing, oldest first."""
    return [
        dict(r)
        for r in db.execute(
            "SELECT seen_on, price, status FROM observations"
            " WHERE id = ? ORDER BY seen_on",
            (listing_id,),
        )
    ]


# --------------------------------------------------------------------------
# The only write
# --------------------------------------------------------------------------


def favourite(db: sqlite3.Connection, listing_id: str, note: str | None) -> None:
    """Mark a listing. Re-marking updates the note rather than erroring.

    `BEGIN IMMEDIATE` rather than sqlite3's implicit deferred transaction: the
    other writer is a batch job, and taking the write lock up front means the
    wait (bounded by busy_timeout) happens here instead of halfway through.
    """
    with db:
        db.execute("BEGIN IMMEDIATE")
        db.execute(
            "INSERT INTO favourites (id, added_on, note) VALUES (?, date('now'), ?)"
            " ON CONFLICT(id) DO UPDATE SET note = excluded.note",
            (listing_id, note),
        )


def unfavourite(db: sqlite3.Connection, listing_id: str) -> None:
    with db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM favourites WHERE id = ?", (listing_id,))


def known(db: sqlite3.Connection, listing_id: str) -> bool:
    return (
        db.execute("SELECT 1 FROM listings WHERE id = ?", (listing_id,)).fetchone()
        is not None
    )


# --------------------------------------------------------------------------
# The page
# --------------------------------------------------------------------------

# Leaflet comes from a CDN, pinned to an exact version with an integrity hash.
# It is not in nixpkgs, and vendoring it would buy nothing: the map's tiles come
# from openstreetmap.org over the same internet, so a page that cannot reach the
# CDN cannot draw a map either. The table below the map renders without any of
# it, which is the fallback that matters.
PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Property board</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
      integrity="sha256-p4NxAoJBhIIN+hmNHrzRCf9tD/miZyoHS5obTRR9BMY="
      crossorigin="">
<style>
  :root { color-scheme: light dark; --bg:#fbfaf8; --fg:#1d1b19; --mut:#6b6560;
          --line:#e2ddd6; --card:#fff; --accent:#8a5a2b; --fav:#c2410c; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#171614; --fg:#eceae7; --mut:#9a938c; --line:#2e2b27;
            --card:#1f1e1b; --accent:#d2a06a; --fav:#f97316; }
  }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--fg);
         font:14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
  header { padding:1rem 1.25rem .75rem; border-bottom:1px solid var(--line); }
  h1 { margin:0; font-size:1.1rem; font-weight:620; letter-spacing:-.01em; }
  .note { margin:.35rem 0 0; color:var(--mut); font-size:.82rem; max-width:62ch; }
  .bar { display:flex; gap:.5rem; flex-wrap:wrap; align-items:center;
         padding:.6rem 1.25rem; border-bottom:1px solid var(--line); }
  .bar label { color:var(--mut); font-size:.8rem; }
  select, input[type=search] { font:inherit; padding:.25rem .4rem;
         border:1px solid var(--line); border-radius:5px;
         background:var(--card); color:var(--fg); }
  #map { height:46vh; min-height:280px; background:var(--card); }
  main { padding:0 1.25rem 3rem; }
  table { width:100%; border-collapse:collapse; margin-top:1rem; }
  th { text-align:left; font-size:.72rem; text-transform:uppercase;
       letter-spacing:.06em; color:var(--mut); font-weight:600;
       padding:.5rem .5rem; border-bottom:1px solid var(--line); }
  td { padding:.55rem .5rem; border-bottom:1px solid var(--line);
       vertical-align:top; }
  tr.sel td { background:color-mix(in srgb, var(--accent) 10%, transparent); }
  .addr { font-weight:560; }
  .sub { color:var(--mut); font-size:.8rem; }
  .num { text-align:right; white-space:nowrap; font-variant-numeric:tabular-nums; }
  .drop { color:#15803d; font-size:.8rem; }
  .verdict { color:var(--mut); font-size:.82rem; max-width:44ch; }
  .pill { display:inline-block; padding:.05rem .4rem; border-radius:999px;
          font-size:.72rem; border:1px solid var(--line); color:var(--mut); }
  .star { cursor:pointer; background:none; border:0; font-size:1.1rem;
          color:var(--mut); padding:0 .2rem; line-height:1; }
  .star.on { color:var(--fav); }
  .spark { display:block; }
  .scroll { overflow-x:auto; }
  .empty { color:var(--mut); padding:2rem 0; }
</style>
</head>
<body>
<header>
  <h1>Property board</h1>
  <p class="note">Pins are <strong>street-level, not front doors</strong> &mdash;
     the portal fuzzes each listing&rsquo;s exact location, so a pin marks
     roughly where something is and never which building it is. Check the
     listing itself before acting on a position.</p>
</header>
<div class="bar">
  <label>Status <select id="status">
    <option value="live">live</option>
    <option value="">all</option>
    <option value="under_offer">under offer</option>
    <option value="withdrawn">withdrawn</option>
  </select></label>
  <label><input type="checkbox" id="favonly"> favourites only</label>
  <label>Search <input type="search" id="q" placeholder="address, agent, verdict"></label>
  <span class="sub" id="count"></span>
</div>
<div id="map"></div>
<main>
  <div class="scroll"><table>
    <thead><tr>
      <th></th><th>Address</th><th class="num">Price</th><th class="num">Beds</th>
      <th>Tenure</th><th class="num">Days</th><th class="num">Score</th>
      <th>Verdict</th><th>History</th>
    </tr></thead>
    <tbody id="rows"></tbody>
  </table></div>
  <p class="empty" id="empty" hidden>Nothing matches.</p>
</main>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
        integrity="sha256-20nQCchB9co0qIjJZRGuk2/Z9VM+kNiyxNV1lvTlZBo="
        crossorigin=""></script>
<script>
// The path this board is served under, substituted in by `page()`. Empty when
// the board owns a whole name; "/property" when it is one of several behind the
// shared `boards` vhost (property#8). Caddy forwards the prefix rather than
// stripping it, so every URL this page builds must carry it.
const BASE = "__BASE__";
const money = n => n == null ? "\\u2014" : "\\u00a3" + n.toLocaleString("en-GB");
const esc = s => (s == null ? "" : String(s)).replace(/[&<>"]/g,
  c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

let all = [], markers = {}, map = null, layer = null, selected = null;

function sparkline(series) {
  const pts = series.filter(o => o.price != null);
  if (pts.length < 2) return "";
  const xs = pts.map((_, i) => i), ys = pts.map(o => o.price);
  const lo = Math.min(...ys), hi = Math.max(...ys), span = hi - lo || 1;
  const w = 90, h = 22;
  const d = pts.map((o, i) =>
    (i ? "L" : "M") + (i / (xs.length - 1) * w).toFixed(1) + " " +
    (h - (o.price - lo) / span * h).toFixed(1)).join(" ");
  return '<svg class="spark" width="' + w + '" height="' + h +
    '" viewBox="0 0 ' + w + ' ' + h + '" aria-hidden="true">' +
    '<path d="' + d + '" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>';
}

function matches(r) {
  const st = document.getElementById("status").value;
  if (st && r.status !== st) return false;
  if (document.getElementById("favonly").checked && !r.favourite) return false;
  const q = document.getElementById("q").value.trim().toLowerCase();
  if (!q) return true;
  return [r.address, r.title, r.agent, r.verdict, r.outcode]
    .some(v => v && String(v).toLowerCase().includes(q));
}

async function toggleFav(r, btn) {
  if (r.favourite) {
    await fetch(BASE + "/api/favourites/" + encodeURIComponent(r.id), {method: "DELETE"});
    r.favourite = false;
  } else {
    const res = await fetch(BASE + "/api/favourites", {
      method: "POST", headers: {"Content-Type": "application/json"},
      body: JSON.stringify({id: r.id, note: null})});
    if (!res.ok) { alert("Could not save that favourite."); return; }
    r.favourite = true;
  }
  btn.classList.toggle("on", r.favourite);
  btn.textContent = r.favourite ? "\\u2605" : "\\u2606";
  if (document.getElementById("favonly").checked) render();
}

function render() {
  const rows = all.filter(matches);
  document.getElementById("count").textContent =
    rows.length + " of " + all.length + " listings";
  const tbody = document.getElementById("rows");
  tbody.textContent = "";
  document.getElementById("empty").hidden = rows.length > 0;

  for (const r of rows) {
    const tr = document.createElement("tr");
    tr.id = "row-" + r.id;
    tr.innerHTML =
      '<td></td>' +
      '<td><div class="addr">' + esc(r.address || r.title || r.id) + '</div>' +
        '<div class="sub">' + esc(r.kind || "") + " \\u00b7 " + esc(r.outcode) +
        " \\u00b7 " + '<span class="pill">' + esc(r.status.replace("_", " ")) +
        '</span>' + (r.mappable ? "" : ' <span class="pill">no position</span>') +
        (r.url ? ' \\u00b7 <a href="' + esc(r.url) + '" target="_blank" rel="noreferrer">listing</a>' : "") +
        '</div></td>' +
      '<td class="num">' + money(r.price) +
        (r.price_drop > 0 ? '<div class="drop">\\u2193 ' + money(r.price_drop) +
          ' from ' + money(r.first_price) + '</div>' : "") + '</td>' +
      '<td class="num">' + (r.bedrooms == null ? "\\u2014" : r.bedrooms) + '</td>' +
      '<td>' + esc((r.tenure || "unknown").replace(/_/g, " ")) + '</td>' +
      '<td class="num">' + (r.days_on_market == null ? "\\u2014" : r.days_on_market) + '</td>' +
      '<td class="num">' + (r.score == null ? "\\u2014" : r.score) + '</td>' +
      '<td class="verdict">' + esc(r.verdict || "") + '</td>' +
      '<td class="num" id="hist-' + esc(r.id) + '"></td>';
    const btn = document.createElement("button");
    btn.className = "star" + (r.favourite ? " on" : "");
    btn.textContent = r.favourite ? "\\u2605" : "\\u2606";
    btn.title = "Favourite";
    btn.onclick = () => toggleFav(r, btn);
    tr.firstChild.appendChild(btn);
    tr.onclick = ev => { if (ev.target.tagName !== "A" && ev.target.tagName !== "BUTTON") focusOn(r); };
    tbody.appendChild(tr);
    fetch(BASE + "/api/listings/" + encodeURIComponent(r.id) + "/history")
      .then(x => x.json())
      .then(h => { const c = document.getElementById("hist-" + r.id);
                   if (c) c.innerHTML = sparkline(h); })
      .catch(() => {});
  }
  drawMap(rows);
}

function focusOn(r) {
  document.querySelectorAll("tr.sel").forEach(t => t.classList.remove("sel"));
  const tr = document.getElementById("row-" + r.id);
  if (tr) { tr.classList.add("sel"); tr.scrollIntoView({block: "nearest"}); }
  if (map && r.mappable) { map.setView([r.lat, r.lon], Math.max(map.getZoom(), 15)); }
  if (markers[r.id]) markers[r.id].openPopup();
}

function drawMap(rows) {
  if (!window.L) return;
  if (!map) {
    map = L.map("map");
    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 19, attribution: "&copy; OpenStreetMap contributors"}).addTo(map);
    map.setView([51.46, -0.05], 12);
  }
  if (layer) layer.remove();
  markers = {};
  layer = L.layerGroup().addTo(map);
  const pts = [];
  for (const r of rows.filter(x => x.mappable)) {
    const m = L.circleMarker([r.lat, r.lon], {
      radius: r.favourite ? 9 : 6, weight: 2,
      color: r.favourite ? "#c2410c" : "#8a5a2b",
      fillColor: r.status === "live" ? "#8a5a2b" : "#9a938c", fillOpacity: .8});
    m.bindPopup('<strong>' + esc(r.address || r.title || r.id) + '</strong><br>' +
      money(r.price) + ' \\u00b7 ' + (r.bedrooms == null ? "?" : r.bedrooms) + ' bed \\u00b7 ' +
      esc((r.tenure || "unknown").replace(/_/g, " ")) + '<br>' +
      (r.score == null ? "" : '<em>' + r.score + '/10 \\u2014 ' + esc(r.verdict || "") + '</em><br>') +
      '<span style="color:#6b6560">Street-level only, not the exact building.</span>' +
      (r.url ? '<br><a href="' + esc(r.url) + '" target="_blank" rel="noreferrer">listing</a>' : ""));
    m.on("click", () => focusOn(r));
    m.addTo(layer);
    markers[r.id] = m;
    pts.push([r.lat, r.lon]);
  }
  if (pts.length) map.fitBounds(pts, {padding: [30, 30], maxZoom: 15});
}

for (const id of ["status", "favonly", "q"]) {
  document.getElementById(id).addEventListener("input", render);
}

fetch(BASE + "/api/listings").then(r => r.json()).then(rows => { all = rows; render(); });
</script>
</body>
</html>
"""


# --------------------------------------------------------------------------
# The HTTP surface
# --------------------------------------------------------------------------

_HISTORY = re.compile(r"^/api/listings/([^/]+)/history$")
_FAVOURITE = re.compile(r"^/api/favourites/([^/]+)$")


def normalise_base(base: str) -> str:
    """The canonical form of a serving prefix: "" or "/segment", no trailing /.

    Normalised once, here, rather than defended against at each of the four
    places that join it to a path -- "property", "/property" and "/property/"
    all mean the same thing to whoever writes the unit, and only one of them
    concatenates correctly.
    """
    base = base.strip().strip("/")
    return "/" + base if base else ""


def page(base: str = "") -> str:
    """The page, with its URLs pointed at wherever this board is served.

    The prefix reaches the browser as a JS constant rather than being baked
    into each URL, so there is one substitution to get right instead of four.
    """
    return PAGE.replace("__BASE__", normalise_base(base))


def make_handler(db_path: str, base: str = ""):
    # Normalised once per handler class, not per request.
    base = normalise_base(base)

    class Handler(BaseHTTPRequestHandler):
        server_version = "property-board/1"
        protocol_version = "HTTP/1.1"

        # A connection per request, not one shared across threads: sqlite3
        # connections are not safe to hand between threads, and a request here
        # is a couple of milliseconds of querying against a local file.
        def _db(self):
            return connect(db_path)

        def _send(self, status, body, ctype):
            if isinstance(body, str):
                body = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            # The board is one person's view of their own search; nothing here
            # should be cached by anything between it and the browser.
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, status, payload):
            self._send(status, json.dumps(payload), "application/json")

        def _fail(self, status, why):
            self._json(status, {"error": why})

        def log_message(self, fmt, *args):
            # One line per request into the journal, without the default's
            # client-address noise -- every client is a tailnet peer.
            sys.stderr.write("%s\n" % (fmt % args))

        def _route(self):
            """The request path with this board's serving prefix removed.

            `None` means the request fell outside the board's URL space, which
            is a 404 and not a redirect: when Caddy routes `/property*` here,
            anything this process sees without that prefix arrived by mistake,
            and answering it would create a second URL the page could be
            emitted into -- one that does not work through the shared vhost.

            Note `/property` (no trailing slash) maps to `/`, because that is
            what a human types and Caddy forwards it verbatim.
            """
            if not base:
                return self.path
            if self.path == base:
                return "/"
            if self.path.startswith(base + "/"):
                return self.path[len(base) :]
            return None

        def do_GET(self):
            route = self._route()
            if route is None:
                return self._fail(404, "no such path")
            if route in ("/", "/index.html"):
                return self._send(200, page(base), "text/html; charset=utf-8")
            if route == "/healthz":
                return self._json(200, {"ok": True})
            if route == "/api/listings":
                db = self._db()
                try:
                    return self._json(200, listings(db))
                finally:
                    db.close()
            m = _HISTORY.match(route)
            if m:
                db = self._db()
                try:
                    return self._json(200, history(db, m.group(1)))
                finally:
                    db.close()
            return self._fail(404, "no such path")

        def _body(self):
            n = int(self.headers.get("Content-Length") or 0)
            if not n:
                return {}
            try:
                return json.loads(self.rfile.read(n))
            except (ValueError, UnicodeDecodeError):
                return None

        def do_POST(self):
            if self._route() != "/api/favourites":
                return self._fail(404, "no such path")
            payload = self._body()
            if not isinstance(payload, dict) or not payload.get("id"):
                return self._fail(400, "need an id")
            db = self._db()
            try:
                if not known(db, payload["id"]):
                    # The job reads this table to tell you when something you
                    # favourited moves. A row pointing at no listing is one it
                    # can never resolve.
                    return self._fail(404, "no such listing")
                favourite(db, payload["id"], payload.get("note"))
                return self._json(200, {"id": payload["id"], "favourite": True})
            finally:
                db.close()

        def do_DELETE(self):
            route = self._route()
            m = _FAVOURITE.match(route) if route else None
            if not m:
                return self._fail(404, "no such path")
            db = self._db()
            try:
                unfavourite(db, m.group(1))
                return self._json(200, {"id": m.group(1), "favourite": False})
            finally:
                db.close()

    return Handler


def make_server(
    host: str, port: int, db_path: str, base: str = ""
) -> ThreadingHTTPServer:
    ThreadingHTTPServer.allow_reuse_address = True
    return ThreadingHTTPServer((host, port), make_handler(db_path, base))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", required=True, help="the shared property-watch database")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9120)
    # The path prefix this board is served under on the shared `boards` vhost
    # (property#8). Caddy forwards the prefix rather than stripping it, so this
    # process routes on it and the page emits its links under it -- one URL
    # space end to end, the one the browser is looking at. Empty by default, so
    # running it by hand on a laptop still answers at `/`.
    ap.add_argument("--base-path", default="", help="e.g. /property")
    args = ap.parse_args(argv)

    # Fail at start rather than on the first request, so a misconfigured path
    # shows up as a unit that will not come up instead of a page that 500s.
    connect(args.db).close()

    srv = make_server(args.host, args.port, args.db, args.base_path)
    base = normalise_base(args.base_path)
    sys.stderr.write(
        f"property-board listening on {args.host}:{args.port}{base or '/'}\n"
    )
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
