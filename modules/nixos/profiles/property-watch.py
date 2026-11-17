#!/usr/bin/env python3
"""Detect what moved in the for-sale market across a set of outcodes.

The deterministic half of the property-watch agent job: this fetches, filters,
records and diffs. It never judges. Its stdout is the delta -- what is new,
what changed price, what went under offer, what withdrew -- and on a day when
nothing moved it prints nothing at all, so `--monitor-script` hashes the same
bytes as yesterday and the model is never woken.

Stdout therefore carries NO timestamps, no run counters and no ordering that
depends on dict iteration. Two runs against an unchanged market must be
byte-identical or the suppression is dead and every day costs a model call.

Hard filters live here because they are facts (a price is over budget or it is
not). Everything soft -- is that garden a garden, is this service charge
affordable, is a maisonette close enough to a house -- is the model's, and is
written in AGENTS.md beside the database rather than in this file.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date

UA = "property-watch/1.0 (+thomas@palebluebytes.space)"

# OnTheMarket's terms permit a crawler that identifies itself and obeys
# robots.txt; their robots.txt sets Crawl-delay: 1. We take 1.2s and one sweep
# a day. That permission is the reason this source was chosen over richer ones,
# so the delay is not a tunable.
CRAWL_DELAY = 1.2

# A listing has to be absent this many consecutive runs before we call it gone.
# One bad fetch must never be able to fabricate a withdrawal.
ABSENCES_BEFORE_WITHDRAWN = 3

# If an outcode returns less than this fraction of what it returned last run,
# treat the whole sweep as suspect and record nothing. Protects against the
# portal half-answering, which otherwise reads as a mass withdrawal.
SANITY_FLOOR = 0.5


# --------------------------------------------------------------------------
# Sources
#
# One class per portal. A source yields normalised dicts and knows nothing
# about the database or the diff. Adding a second source -- a scraping path,
# a paid API -- means another class here and a name in the config, and nothing
# downstream changes.
# --------------------------------------------------------------------------


class OnTheMarket:
    name = "onthemarket"
    BASE = "https://www.onthemarket.com/async/search/properties/"

    def __init__(self, max_price: int, min_bedrooms: int):
        self.max_price = max_price
        self.min_bedrooms = min_bedrooms

    def _get(self, params: dict) -> dict:
        url = self.BASE + "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=45) as r:
            return json.load(r)

    def fetch(self, outcode: str) -> tuple[list[dict], int]:
        """Return (listings, portal's own total) for one outcode."""
        params = {
            "search-type": "for-sale",
            "location-id": outcode.lower(),
            "max-price": str(self.max_price),
            "min-bedrooms": str(self.min_bedrooms),
        }
        first = self._get(params)
        total = first.get("total-results", 0)
        pages = 1
        last = (first.get("pagination-controls") or {}).get("last-link")
        if last:
            pages = int(last.get("page", 1))

        out = [self._normalise(p, outcode) for p in first.get("properties", [])]
        for page in range(2, pages + 1):
            time.sleep(CRAWL_DELAY)
            d = self._get({**params, "page": str(page)})
            out.extend(self._normalise(p, outcode) for p in d.get("properties", []))
        return [r for r in out if r], total

    # Tenure arrives as a feature string: "Tenure: Share of freehold",
    # "Tenure: Leasehold (118 years remaining)". Absent on roughly 5%.
    _TENURE = re.compile(
        r"^Tenure:\s*(.+?)\s*(?:\((\d+)\s*years remaining\))?$", re.IGNORECASE
    )

    def _normalise(self, p: dict, outcode: str) -> dict | None:
        pid = p.get("id")
        if not pid:
            return None

        features = [f for f in (p.get("features") or []) if isinstance(f, str)]

        tenure, lease_years = None, None
        for f in features:
            m = self._TENURE.match(f)
            if m:
                raw = m.group(1).strip().lower()
                lease_years = int(m.group(2)) if m.group(2) else None
                if "share of freehold" in raw:
                    tenure = "share_of_freehold"
                elif "freehold" in raw:
                    tenure = "freehold"
                elif "leasehold" in raw:
                    tenure = "leasehold"
                else:
                    tenure = raw
                break

        qualifier = p.get("price-qualifier")
        # Auction is a features entry. An auction HOUSE selling a normal
        # property is not an auction sale, so the agent name is deliberately
        # not part of this test -- it becomes a flag instead.
        auction = any(f.strip().lower().startswith("auction") for f in features)
        agent = (p.get("agent") or {}).get("name") or ""
        auction_agent = "auction" in agent.lower()

        blob = " ".join(
            features + [p.get("property-serp-title") or "", qualifier or ""]
        ).lower()
        shared_ownership = (qualifier or "").strip().lower() == "shared ownership" or (
            "shared ownership" in blob or "shared-ownership" in blob
        )

        loc = p.get("location") or {}
        return {
            "id": f"otm:{pid}",
            "source": self.name,
            "outcode": (p.get("postcode1") or outcode).upper(),
            "price": _money(p.get("price")),
            "price_qualifier": qualifier,
            "bedrooms": p.get("bedrooms"),
            "bathrooms": p.get("bathrooms"),
            "title": p.get("property-serp-title"),
            "address": p.get("display_address"),
            "kind": _kind(p.get("property-serp-title")),
            "tenure": tenure,
            "lease_years": lease_years,
            "auction": auction,
            "auction_agent": auction_agent,
            "shared_ownership": shared_ownership,
            "agent": agent,
            "lat": loc.get("lat"),
            "lon": loc.get("lon"),
            "url": "https://www.onthemarket.com" + (p.get("property-link") or ""),
            "features": features,
            "raw": p,
        }


SOURCES = {"onthemarket": OnTheMarket}


def _money(s) -> int | None:
    if not isinstance(s, str):
        return None
    digits = re.sub(r"[^0-9]", "", s)
    return int(digits) if digits else None


def _kind(title: str | None) -> str:
    """Coarse property kind from the listing title."""
    t = (title or "").lower()
    for needle, kind in (
        ("maisonette", "maisonette"),
        ("terraced house", "house"),
        ("end of terrace", "house"),
        ("semi-detached house", "house"),
        ("detached house", "house"),
        ("town house", "house"),
        ("house", "house"),
        ("bungalow", "house"),
        ("duplex", "flat"),
        ("apartment", "flat"),
        ("flat", "flat"),
    ):
        if needle in t:
            return kind
    return "other"


# --------------------------------------------------------------------------
# Hard filters
#
# Only facts. A listing that fails one of these is never shown; a listing with
# a fact MISSING is kept and marked unknown, because silently dropping the 5%
# with no stated tenure would hide them from you and from the model both.
# --------------------------------------------------------------------------


def hard_filter(r: dict, cfg: dict) -> str | None:
    """Return a reason to exclude, or None to keep."""
    if r["outcode"] not in cfg["outcodes"]:
        return "outside target outcodes"
    if r["price"] is None:
        return "no price stated"
    if r["price"] > cfg["max_price"]:
        return "over budget"
    if (r["bedrooms"] or 0) < cfg["min_bedrooms"]:
        return "too few bedrooms"
    if r["shared_ownership"]:
        return "shared ownership"
    if r["auction"]:
        return "auction"
    if r["tenure"] == "leasehold":
        return "leasehold"
    return None


# --------------------------------------------------------------------------
# Storage
# --------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS listings (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  outcode TEXT NOT NULL,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  absences INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'live',      -- live | under_offer | withdrawn
  first_price INTEGER,
  price INTEGER,
  bedrooms INTEGER, bathrooms INTEGER,
  title TEXT, address TEXT, kind TEXT,
  tenure TEXT, lease_years INTEGER,
  auction_agent INTEGER DEFAULT 0,
  agent TEXT, lat REAL, lon REAL, url TEXT,
  features TEXT,
  raw TEXT,                                  -- verbatim source record
  score INTEGER, verdict TEXT,               -- written by the model, not here
  relist_of TEXT
);
CREATE TABLE IF NOT EXISTS observations (
  id TEXT NOT NULL, seen_on TEXT NOT NULL,
  price INTEGER, status TEXT,
  PRIMARY KEY (id, seen_on)
);
CREATE TABLE IF NOT EXISTS favourites (   -- the board writes this, we only read
  id TEXT PRIMARY KEY, added_on TEXT NOT NULL, note TEXT
);
CREATE TABLE IF NOT EXISTS sweeps (
  outcode TEXT NOT NULL, seen_on TEXT NOT NULL, total INTEGER, kept INTEGER,
  PRIMARY KEY (outcode, seen_on)
);
CREATE INDEX IF NOT EXISTS obs_id ON observations(id);
CREATE INDEX IF NOT EXISTS listings_status ON listings(status);
"""


def connect(path: str) -> sqlite3.Connection:
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)
    return db


# --------------------------------------------------------------------------
# The sweep and the diff
# --------------------------------------------------------------------------


def sweep(db: sqlite3.Connection, cfg: dict, today: str, log) -> dict[str, dict]:
    src = SOURCES[cfg.get("source", "onthemarket")](
        cfg["max_price"], cfg["min_bedrooms"]
    )
    seen: dict[str, dict] = {}
    for i, oc in enumerate(cfg["outcodes"]):
        if i:
            time.sleep(CRAWL_DELAY)
        try:
            rows, total = src.fetch(oc)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            raise FetchFailed(f"{oc}: {e}") from e

        prev = db.execute(
            "SELECT total FROM sweeps WHERE outcode=? ORDER BY seen_on DESC LIMIT 1",
            (oc,),
        ).fetchone()
        if prev and prev["total"] and total < prev["total"] * SANITY_FLOOR:
            raise FetchFailed(
                f"{oc}: {total} results against {prev['total']} last run -- refusing to record"
            )

        kept = 0
        for r in rows:
            if hard_filter(r, cfg) is None:
                seen[r["id"]] = r
                kept += 1
        log(f"{oc.upper():6} {total:5} total  {kept:4} kept")
        db.execute(
            "INSERT OR REPLACE INTO sweeps(outcode,seen_on,total,kept) VALUES (?,?,?,?)",
            (oc, today, total, kept),
        )
    return seen


class FetchFailed(RuntimeError):
    pass


def record(
    db: sqlite3.Connection, seen: dict[str, dict], today: str
) -> dict[str, list]:
    delta: dict[str, list] = {
        "new": [],
        "reduced": [],
        "increased": [],
        "withdrawn": [],
        "relisted": [],
    }

    known = {r["id"]: r for r in db.execute("SELECT * FROM listings")}

    for pid, r in seen.items():
        old = known.get(pid)
        if old is None:
            relist_of = find_relist(db, r)
            db.execute(
                """INSERT INTO listings
                   (id,source,outcode,first_seen,last_seen,absences,status,
                    first_price,price,bedrooms,bathrooms,title,address,kind,
                    tenure,lease_years,auction_agent,agent,lat,lon,url,features,raw,relist_of)
                   VALUES (?,?,?,?,?,0,'live',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    pid,
                    r["source"],
                    r["outcode"],
                    today,
                    today,
                    r["price"],
                    r["price"],
                    r["bedrooms"],
                    r["bathrooms"],
                    r["title"],
                    r["address"],
                    r["kind"],
                    r["tenure"],
                    r["lease_years"],
                    int(r["auction_agent"]),
                    r["agent"],
                    r["lat"],
                    r["lon"],
                    r["url"],
                    json.dumps(r["features"], sort_keys=True),
                    json.dumps(r["raw"], sort_keys=True),
                    relist_of,
                ),
            )
            entry = dict(r, first_seen=today, relist_of=relist_of)
            if relist_of:
                entry["previous"] = known.get(relist_of)
                delta["relisted"].append(entry)
            else:
                delta["new"].append(entry)
        else:
            if old["status"] == "withdrawn":
                db.execute("UPDATE listings SET status='live' WHERE id=?", (pid,))
            if (
                r["price"] is not None
                and old["price"] is not None
                and r["price"] != old["price"]
            ):
                entry = dict(
                    r,
                    first_seen=old["first_seen"],
                    was=old["price"],
                    first_price=old["first_price"],
                )
                delta["reduced" if r["price"] < old["price"] else "increased"].append(
                    entry
                )
            db.execute(
                "UPDATE listings SET last_seen=?,absences=0,price=?,tenure=COALESCE(?,tenure),raw=? WHERE id=?",
                (
                    today,
                    r["price"],
                    r["tenure"],
                    json.dumps(r["raw"], sort_keys=True),
                    pid,
                ),
            )
        db.execute(
            "INSERT OR REPLACE INTO observations(id,seen_on,price,status) VALUES (?,?,?,'live')",
            (pid, today, r["price"]),
        )

    for pid, old in known.items():
        if pid in seen or old["status"] == "withdrawn":
            continue
        absences = old["absences"] + 1
        if absences >= ABSENCES_BEFORE_WITHDRAWN:
            db.execute(
                "UPDATE listings SET absences=?,status='withdrawn' WHERE id=?",
                (absences, pid),
            )
            delta["withdrawn"].append(dict(old))
        else:
            db.execute("UPDATE listings SET absences=? WHERE id=?", (absences, pid))

    db.commit()
    return delta


def find_relist(db: sqlite3.Connection, r: dict) -> str | None:
    """A withdrawn listing of the same shape nearby is probably this one again.

    Deliberately does NOT merge the records: two flats in one block are a real
    possibility, and fusing them would be worse than reporting a coincidence.
    The collision is passed to the model to describe.
    """
    if r["price"] is None:
        return None
    lo, hi = int(r["price"] * 0.95), int(r["price"] * 1.05)
    hit = db.execute(
        """SELECT id FROM listings
           WHERE status='withdrawn' AND outcode=? AND bedrooms IS ? AND kind=?
             AND price BETWEEN ? AND ?
           ORDER BY last_seen DESC LIMIT 1""",
        (r["outcode"], r["bedrooms"], r["kind"], lo, hi),
    ).fetchone()
    return hit["id"] if hit else None


# --------------------------------------------------------------------------
# The digest -- stable bytes, silent when nothing moved
# --------------------------------------------------------------------------


def fmt_price(p) -> str:
    return f"£{p:,}" if p else "price n/a"


def describe(r: dict) -> str:
    bits = [
        r.get("outcode", ""),
        fmt_price(r.get("price")),
        f"{r.get('bedrooms') or '?'}bed",
        r.get("kind") or "?",
        (r.get("tenure") or "tenure-unknown").replace("_", "-"),
    ]
    if r.get("lease_years"):
        bits.append(f"{r['lease_years']}yr")
    if r.get("auction_agent"):
        bits.append("auction-agent")
    return "  ".join(bits)


def digest(delta: dict[str, list], favourites: set[str]) -> str:
    out: list[str] = []

    def section(key: str, heading: str, render) -> None:
        rows = delta.get(key) or []
        if not rows:
            return
        out.append(f"{heading} ({len(rows)})")
        for r in sorted(
            rows, key=lambda x: (x.get("outcode") or "", x.get("id") or "")
        ):
            star = "* " if r.get("id") in favourites else "  "
            out.append(f"{star}{render(r)}")
        out.append("")

    section(
        "new",
        "NEW",
        lambda r: (
            f"{r['id']}  {describe(r)}  {r.get('title') or ''}\n      {r.get('url')}"
        ),
    )
    section(
        "relisted",
        "BACK ON THE MARKET (possible re-list)",
        lambda r: (
            f"{r['id']}  {describe(r)}  {r.get('title') or ''}\n"
            f"      resembles withdrawn {r.get('relist_of')}"
            + (
                f" last at {fmt_price(dict(r['previous'])['price'])}"
                if r.get("previous") is not None
                else ""
            )
            + f"\n      {r.get('url')}"
        ),
    )
    section(
        "reduced",
        "PRICE REDUCED",
        lambda r: (
            f"{r['id']}  {r.get('outcode')}  {fmt_price(r.get('price'))} "
            f"was {fmt_price(r.get('was'))} "
            f"({(r['price'] - r['was']) / r['was'] * 100:+.1f}%)  "
            f"first listed {r.get('first_seen')} at {fmt_price(r.get('first_price'))}\n"
            f"      {r.get('url')}"
        ),
    )
    section(
        "increased",
        "PRICE INCREASED",
        lambda r: (
            f"{r['id']}  {r.get('outcode')}  {fmt_price(r.get('price'))} "
            f"was {fmt_price(r.get('was'))}\n      {r.get('url')}"
        ),
    )
    section(
        "withdrawn",
        "NO LONGER LISTED",
        lambda r: (
            f"{r['id']}  {r.get('outcode')}  last {fmt_price(r.get('price'))}  "
            f"listed {r.get('first_seen')} to {r.get('last_seen')}"
        ),
    )
    return "\n".join(out).rstrip() + "\n" if out else ""


# --------------------------------------------------------------------------


def export(db: sqlite3.Connection, path: str) -> None:
    rows = [
        # Keep `.keys()`. Iterating a sqlite3.Row yields its VALUES, not its column
        # names, so SIM118's "simplification" here silently produces a dict keyed by the
        # data. That is why ruff itself marks that fix unsafe.
        {k: r[k] for k in r.keys() if k != "raw"}  # noqa: SIM118
        for r in db.execute(
            "SELECT * FROM listings WHERE status!='withdrawn' ORDER BY id"
        )
    ]
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(rows, f, indent=1, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--state", default="/var/lib/property-watch")
    ap.add_argument(
        "--bootstrap",
        action="store_true",
        help="record the corpus and report counts only; emit no delta",
    )
    ap.add_argument("--verbose", action="store_true", help="progress to stderr")
    args = ap.parse_args()

    log = (lambda m: print(m, file=sys.stderr)) if args.verbose else (lambda m: None)

    with open(os.path.join(args.state, "config.json")) as f:
        cfg = json.load(f)
    cfg["outcodes"] = [o.upper() for o in cfg["outcodes"]]

    # The brief is read from the state root (which the agent cannot write); everything
    # the job PRODUCES goes in data/ (which it can). See property-watch.nix.
    db = connect(os.path.join(args.state, "data", "property-watch.db"))
    today = date.today().isoformat()

    try:
        seen = sweep(db, cfg, today, log)
    except FetchFailed as e:
        # Unknown state, not an empty market. Say so on stderr -- which hermes
        # surfaces as a failure -- and leave stdout untouched so the hash is
        # unchanged and nothing is reported as having moved.
        print(f"fetch failed, nothing recorded: {e}", file=sys.stderr)
        return 2

    first_run = db.execute("SELECT COUNT(*) c FROM listings").fetchone()["c"] == 0
    delta = record(db, seen, today)
    export(db, os.path.join(args.state, "data", "listings.json"))

    if first_run or args.bootstrap:
        n = len(seen)
        by = {}
        for r in seen.values():
            by[r["outcode"]] = by.get(r["outcode"], 0) + 1
        print(
            f"BOOTSTRAP: recorded {n} listings across {len(by)} outcodes; no delta reported."
        )
        for oc in sorted(by):
            print(f"  {oc:6} {by[oc]:4}")
        return 0

    favourites = {r["id"] for r in db.execute("SELECT id FROM favourites")}
    sys.stdout.write(digest(delta, favourites))
    return 0


if __name__ == "__main__":
    sys.exit(main())
