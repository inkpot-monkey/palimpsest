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
import contextlib
import html
import json
import os
import re
import sqlite3
import stat
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

# Detail pages are fetched for NEWLY SEEN listings only, one request each. A
# normal day's delta is a handful against a corpus of ~275, so this adds single
# digits to the ~60 requests the sweep already makes -- which is the whole
# reason the prose can be had at all without breaking the bargain in #1.
#
# The budget is not a tuning knob, it is a blast radius. If the portal ever
# changes its ids, or a sweep comes back from a different shard, every listing
# reads as new at once; without a cap that is 275 extra requests in one morning
# from a crawler that promised to be small. Over budget, the listings are still
# recorded in full -- they simply have no prose until a `--backfill` run.
DETAIL_BUDGET = 25

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

    # ── THE DETAIL PAGE ──────────────────────────────────────────────────
    # /async/search/properties/ carries a listing's summary `features` array
    # and nothing else: ['Two Bedroom', 'Allocated Parking']. The prose lives
    # on the listing's own page, and so does every service charge -- which is
    # why the first real run of this job said "garden unstated" on nearly every
    # line and found one service charge in 275 listings (property#6).
    #
    # Two things come back, and the difference between them matters:
    #
    #   * `description` -- the agent's prose, as text. The model reads it. The
    #     script does NOT: pulling a figure out of "£2,000 per annum service
    #     charge and ground rent of £250" is judgement, and a regex that is
    #     wrong one time in ten is worse than no number at all, because a
    #     number in a database is believed.
    #   * `key_info` -- the portal's OWN structured fields, copied across
    #     untouched. "£697 per annum" is stored as that string and not as 697,
    #     for the same reason: the parsing that is safe here is the parsing
    #     OnTheMarket already did.
    _NEXT_DATA = re.compile(
        r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', re.DOTALL
    )
    _BREAK = re.compile(r"<\s*/?\s*(?:br|p|div|li|h[1-6])\b[^>]*>", re.IGNORECASE)
    _TAG = re.compile(r"<[^>]+>")
    _BLANKS = re.compile(r"\n{3,}")

    @classmethod
    def _text(cls, markup: str) -> str:
        """Markup to readable text, losing nothing but the markup.

        The prose arrives as `<br/><b>SUMMARY</b><br/>…` with HTML entities in
        it. Verbatim means nothing is summarised, reordered or dropped -- not
        that `<br/>` is handed to a reader that will never render it.
        """
        t = cls._BREAK.sub("\n", markup)
        t = cls._TAG.sub("", t)
        t = html.unescape(t).replace("\r\n", "\n").replace("\r", "\n")
        t = "\n".join(line.rstrip() for line in t.split("\n"))
        return cls._BLANKS.sub("\n\n", t).strip()

    @classmethod
    def parse_detail(cls, page: str) -> dict:
        """Prose and key facts from a detail page's bytes.

        Never raises. A redesign, a holding page or a 404 body yields a listing
        with no description, which is a listing the model can still see.
        """
        empty = {"description": None, "key_info": {}}
        m = cls._NEXT_DATA.search(page)
        if not m:
            return empty
        try:
            blob = json.loads(m.group(1))
            prop = blob["props"]["pageProps"]["initialReduxState"]["property"]
        except (json.JSONDecodeError, KeyError, TypeError):
            return empty

        desc = prop.get("description")
        key_info = {
            k["title"]: k["value"]
            for k in (prop.get("keyInfo") or [])
            if isinstance(k, dict)
            and isinstance(k.get("title"), str)
            and isinstance(k.get("value"), str)
        }
        return {
            "description": cls._text(desc) or None if isinstance(desc, str) else None,
            "key_info": key_info,
        }

    def detail(self, url: str) -> dict:
        """One detail page, at crawl-delay pace. Not parallelised, on purpose."""
        time.sleep(CRAWL_DELAY)
        req = urllib.request.Request(url, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=45) as r:
            charset = r.headers.get_content_charset() or "utf-8"
            return self.parse_detail(r.read().decode(charset, "replace"))

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
  description TEXT,                          -- the listing's prose, as text
  key_info TEXT,                             -- the portal's own facts, verbatim
  raw TEXT,                                  -- verbatim source record
  relist_of TEXT
);
CREATE TABLE IF NOT EXISTS observations (
  id TEXT NOT NULL, seen_on TEXT NOT NULL,
  price INTEGER, status TEXT,
  PRIMARY KEY (id, seen_on)
);
CREATE TABLE IF NOT EXISTS verdicts (
  -- What the model thought, when, and about WHAT PRICE. A verdict belongs to a
  -- moment, not to a listing: a place that drops £40k gets judged again, and the
  -- old verdict was not wrong -- it was right about a different price. A column
  -- on `listings` would overwrite exactly the thing worth keeping.
  --
  -- No `score`. A model's mark out of ten is not a measurement: the same flat,
  -- judged on two days in two different deltas, scores differently for reasons
  -- that have nothing to do with the property. Stored, it invites a comparison
  -- that was never valid. It stays in the daily message, where it ranks within
  -- one day and is then disposable.
  id TEXT NOT NULL,
  judged_on TEXT NOT NULL,
  verdict TEXT NOT NULL,
  price_at_judgement INTEGER,
  model TEXT, reasoning_effort TEXT,
  trigger TEXT,              -- stamped by the script; the model is never asked
  PRIMARY KEY (id, judged_on)
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


def _share(path: str) -> None:
    """Make `path` writable by the `property-watch` group, if it exists yet.

    THE SECOND PROCESS IS THE REASON. This database is a two-writer contract:
    the job owns `listings`, `observations` and `sweeps`, and the board
    (property#5, profiles/property-board.py) owns `favourites`. They run as
    different users and meet through the group whose GID is pinned at 973.

    sqlite creates its files under the process umask, and hermes-agent's is
    022 -- so the database and its `-wal`/`-shm` siblings land 0644 and the
    board cannot write its own table however the setgid directory is set up.
    The live database was created that way before this existed, so repairing an
    existing file matters as much as creating a new one correctly: a one-off
    chmod would be undone by the next sweep, this is not.
    """
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        return
    if not mode & stat.S_IWGRP:
        try:
            os.chmod(path, mode | stat.S_IWGRP | stat.S_IRGRP)
        except PermissionError:
            # The other process owns it and will fix it on its own next open.
            # Carrying on is right: the job's own writes are unaffected.
            pass


def connect(path: str) -> sqlite3.Connection:
    # New files inherit this, so `-wal` and `-shm` come out group-writable
    # rather than needing to be chased afterwards. A writer needs all three.
    os.umask(0o002)
    db = sqlite3.connect(path, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.executescript(SCHEMA)

    # `CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists,
    # so a column added to SCHEMA never reaches the database that is already out
    # there holding the corpus. Add it here or the first run after a deploy dies
    # on "no such column" -- which, because the sweep comes first, happens after
    # a full ~60-request crawl.
    have = {r["name"] for r in db.execute("PRAGMA table_info(listings)")}
    for col, decl in (("description", "TEXT"), ("key_info", "TEXT")):
        if col not in have:
            db.execute(f"ALTER TABLE listings ADD COLUMN {col} {decl}")

    # `score` was specified before anything wrote it, and property#7 decided
    # nothing ever should. Drop it rather than leave it: a column that exists and
    # is always NULL reads as "the model did not judge this one", which is a
    # different and wrong statement. (DROP COLUMN needs sqlite >= 3.35; rk1b is
    # on 3.54. Guarded anyway so an older host degrades to leaving it in place
    # rather than failing to open the database at all.)
    if "score" in have and sqlite3.sqlite_version_info >= (3, 35):
        db.execute("ALTER TABLE listings DROP COLUMN score")
    db.commit()

    for suffix in ("", "-wal", "-shm"):
        _share(path + suffix)
    return db


# --------------------------------------------------------------------------
# The sweep and the diff
# --------------------------------------------------------------------------


def make_source(cfg: dict):
    return SOURCES[cfg.get("source", "onthemarket")](
        cfg["max_price"], cfg["min_bedrooms"]
    )


def sweep(db: sqlite3.Connection, cfg: dict, today: str, log, src) -> dict[str, dict]:
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


def fetch_details(src, urls: list[str], log=lambda _m: None) -> dict[str, dict]:
    """Detail pages for `urls`, in the order given, one at a time.

    A failure is an absent entry and nothing more. The alternative -- letting it
    propagate -- would drop the listing from the sweep entirely, and three runs
    later the job would report a withdrawal that never happened. A listing with
    no prose is a listing the model can still see.
    """
    out: dict[str, dict] = {}
    for url in urls:
        try:
            out[url] = src.detail(url)
        except Exception as e:  # noqa: BLE001 -- see docstring; nothing is worth the sweep
            log(f"detail fetch failed, listing kept without prose: {url}: {e}")
    return out


def record(
    db: sqlite3.Connection, seen: dict[str, dict], today: str, src=None, log=None
) -> dict[str, list]:
    log = log or (lambda _m: None)
    delta: dict[str, list] = {
        "new": [],
        "reduced": [],
        "increased": [],
        "withdrawn": [],
        "relisted": [],
    }

    known = {r["id"]: r for r in db.execute("SELECT * FROM listings")}

    # NEW LISTINGS ONLY, and sorted so the budget falls the same way on a
    # replay -- the digest's bytes depend on which prose was fetched.
    new_ids = sorted(pid for pid in seen if pid not in known)
    details = (
        fetch_details(src, [seen[pid]["url"] for pid in new_ids[:DETAIL_BUDGET]], log)
        if src is not None
        else {}
    )

    for pid, r in seen.items():
        detail = details.get(r["url"]) or {}
        old = known.get(pid)
        if old is None:
            relist_of = find_relist(db, r)
            db.execute(
                """INSERT INTO listings
                   (id,source,outcode,first_seen,last_seen,absences,status,
                    first_price,price,bedrooms,bathrooms,title,address,kind,
                    tenure,lease_years,auction_agent,agent,lat,lon,url,features,
                    description,key_info,raw,relist_of)
                   VALUES (?,?,?,?,?,0,'live',?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
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
                    detail.get("description"),
                    json.dumps(detail.get("key_info") or {}, sort_keys=True),
                    json.dumps(r["raw"], sort_keys=True),
                    relist_of,
                ),
            )
            entry = dict(
                r,
                first_seen=today,
                relist_of=relist_of,
                description=detail.get("description"),
                key_info=detail.get("key_info") or {},
            )
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
# Verdicts (property#7)
#
# The model writes JSON and invokes `--apply-verdicts`; this is the only door
# into the corpus it has. It never learns the schema, never opens sqlite, and
# cannot insert a listing, delete one, or touch a column it has no business in.
# The blast radius of a bad run is "a verdict is wrong", not "the corpus is
# corrupt" -- which is the whole reason the model is not simply handed the
# database.
# --------------------------------------------------------------------------


def judging_model(hermes_home: str, job_id: str) -> tuple[str | None, str | None]:
    """Which model is about to judge, read from hermes's own bookkeeping.

    `jobs.json` is the authority and the only thing that cannot drift: the model
    is imperative state (`hermes cron edit --model ...`), so a value duplicated
    into the flake or an env var goes stale the first time anyone changes it --
    and a verdict attributed to the wrong model is worse than one attributed to
    none, because it would be believed.

    Returns (None, None) when it cannot be read. Attribution is nice to have;
    failing a night's judgement over it would not be.
    """
    try:
        with open(os.path.join(hermes_home, "cron", "jobs.json")) as f:
            jobs = json.load(f).get("jobs") or []
    except (OSError, ValueError):
        return (None, None)
    for j in jobs:
        if j.get("id") == job_id:
            return (j.get("model"), j.get("reasoning_effort"))
    return (None, None)


def stored_triggers(db: sqlite3.Connection, today: str) -> dict[str, str]:
    """Why each listing was in today's delta, as a FACT the script already knows.

    Derived from what was recorded rather than asked of the model: it would have
    to be told in order to answer, and could then get it wrong. A listing first
    seen today is new; one whose price differs from yesterday's observation
    moved, and which way.
    """
    out: dict[str, str] = {}
    for r in db.execute(
        """SELECT l.id, l.first_seen, l.relist_of, l.price AS now,
                  (SELECT o.price FROM observations o
                    WHERE o.id = l.id AND o.seen_on < ?
                    ORDER BY o.seen_on DESC LIMIT 1) AS before
           FROM listings l WHERE l.last_seen = ?""",
        (today, today),
    ):
        if r["first_seen"] == today:
            out[r["id"]] = "relisted" if r["relist_of"] else "new"
        elif (
            r["before"] is not None and r["now"] is not None and r["now"] != r["before"]
        ):
            out[r["id"]] = "reduced" if r["now"] < r["before"] else "increased"
    return out


def apply_verdicts(
    db: sqlite3.Connection,
    payload,
    today: str,
    model: str | None = None,
    reasoning_effort: str | None = None,
    triggers: dict[str, str] | None = None,
) -> tuple[int, list[str]]:
    """Apply what the model judged. Returns (applied, [rejection reasons]).

    Validation is the enforcement: nothing constrains what the model emits, so
    anything this does not check reaches the corpus. Bad rows are rejected
    individually and the good ones still land -- one malformed entry must not
    cost a whole night's judgement.
    """
    rejected: list[str] = []
    applied = 0
    triggers = triggers or {}

    if not isinstance(payload, list):
        return 0, [f"expected a list of verdicts, got {type(payload).__name__}"]

    known = {r["id"]: r["price"] for r in db.execute("SELECT id, price FROM listings")}

    for i, item in enumerate(payload):
        if not isinstance(item, dict):
            rejected.append(f"[{i}] not an object")
            continue
        pid = item.get("id")
        verdict = item.get("verdict")
        if not isinstance(pid, str) or not pid:
            rejected.append(f"[{i}] missing or non-string id")
            continue
        if not isinstance(verdict, str) or not verdict.strip():
            rejected.append(f"[{i}] {pid}: missing or empty verdict")
            continue
        if pid not in known:
            # The model inventing an id, or judging something it was not shown,
            # is the failure that would quietly corrupt the record. Refuse it.
            rejected.append(f"[{i}] {pid}: unknown listing")
            continue
        db.execute(
            """INSERT OR REPLACE INTO verdicts
               (id, judged_on, verdict, price_at_judgement, model, reasoning_effort, trigger)
               VALUES (?,?,?,?,?,?,?)""",
            (
                pid,
                today,
                verdict.strip(),
                known[pid],
                model,
                reasoning_effort,
                triggers.get(pid),
            ),
        )
        applied += 1

    db.commit()
    return applied, rejected


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


def prose(r: dict) -> str:
    """The listing's own words, indented under its line, or nothing.

    This is the point of property#6. The digest IS the prompt -- the model gets
    these bytes and nothing else unless it goes looking -- so prose that landed
    only in the database is prose the model does not read, which is exactly
    what the first real run demonstrated. It appears for NEW and RELISTED
    listings alone, which are the ones that have just been fetched; everything
    else is a line about a price, and does not need a page of description under
    it.
    """
    out = []
    for title, value in sorted((r.get("key_info") or {}).items()):
        out.append(f"      {title}: {value}")
    for line in (r.get("description") or "").split("\n"):
        out.append(f"      {line}".rstrip())
    return ("\n" + "\n".join(out)) if out else ""


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
            f"{r['id']}  {describe(r)}  {r.get('title') or ''}\n"
            f"      {r.get('url')}" + prose(r)
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
            + prose(r)
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


def backfill(db: sqlite3.Connection, src, limit: int, log) -> int:
    """Fetch prose for listings recorded BEFORE this feature existed.

    Deliberately not part of the daily run. The corpus was ~275 when the prose
    started being collected, and quietly draining that backlog would mean
    hundreds of extra requests spread over days that the crawl bargain in #1
    never accounted for. This is an operator running a bounded number of
    requests on purpose, with `--backfill N` naming the number.
    """
    rows = db.execute(
        "SELECT id,url FROM listings WHERE description IS NULL AND status!='withdrawn'"
        " ORDER BY id LIMIT ?",
        (limit,),
    ).fetchall()
    by_url = {r["url"]: r["id"] for r in rows}
    details = fetch_details(src, [r["url"] for r in rows], log)
    for url, d in details.items():
        db.execute(
            "UPDATE listings SET description=?,key_info=? WHERE id=?",
            (
                d.get("description"),
                json.dumps(d.get("key_info") or {}, sort_keys=True),
                by_url[url],
            ),
        )
    db.commit()
    return len(details)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--state", default="/var/lib/property-watch")
    ap.add_argument(
        "--bootstrap",
        action="store_true",
        help="record the corpus and report counts only; emit no delta",
    )
    ap.add_argument(
        "--backfill",
        type=int,
        metavar="N",
        help="fetch prose for up to N stored listings that have none, then stop. "
        "For the corpus recorded before descriptions were collected; not part "
        "of the daily run, and prints nothing on stdout.",
    )
    ap.add_argument(
        "--apply-verdicts",
        metavar="FILE",
        help="apply the model's judgements from FILE (a JSON list of "
        "{id, verdict}), then stop. This is the ONLY door the model has into "
        "the corpus: it writes the file and calls this, and the script does "
        "every write. Prints nothing on stdout -- see the note there.",
    )
    ap.add_argument(
        "--judge-backlog",
        type=int,
        metavar="N",
        help="list up to N stored listings that have never been judged, as "
        "JSON on STDERR, for an operator-driven one-off catch-up. Unlike "
        "--backfill this exists to spend MODEL tokens, so it is never "
        "automatic and never part of the daily run.",
    )
    ap.add_argument("--verbose", action="store_true", help="progress to stderr")
    args = ap.parse_args(argv)

    log = (lambda m: print(m, file=sys.stderr)) if args.verbose else (lambda m: None)

    with open(os.path.join(args.state, "config.json")) as f:
        cfg = json.load(f)
    cfg["outcodes"] = [o.upper() for o in cfg["outcodes"]]

    # The brief is read from the state root (which the agent cannot write); everything
    # the job PRODUCES goes in data/ (which it can). See property-watch.nix.
    db = connect(os.path.join(args.state, "data", "property-watch.db"))
    today = date.today().isoformat()
    src = make_source(cfg)

    if args.apply_verdicts:
        # NOTHING GOES TO STDOUT HERE. `--monitor-script` hashes stdout exactly,
        # so a byte written on this path would change the hash on every run that
        # judged anything -- waking the model every morning, forever, while the
        # job carried on looking perfectly healthy. Rejections go to stderr,
        # which hermes surfaces as run output.
        try:
            with open(args.apply_verdicts) as f:
                payload = json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            print(f"could not read verdicts: {e}", file=sys.stderr)
            return 2
        # HERMES_HOME and the job id come from the unit; see property-watch.nix.
        model, effort = judging_model(
            os.environ.get("HERMES_HOME", ""),
            os.environ.get("PROPERTY_WATCH_JOB_ID", ""),
        )
        applied, rejected = apply_verdicts(
            db,
            payload,
            today,
            model=model,
            reasoning_effort=effort,
            triggers=stored_triggers(db, today),
        )
        for r in rejected:
            print(f"rejected verdict {r}", file=sys.stderr)
        print(f"applied {applied} verdicts, rejected {len(rejected)}", file=sys.stderr)
        # Consumed on purpose: a file left behind would be re-applied on the
        # next run and silently re-date a verdict to a day nobody judged it.
        with contextlib.suppress(OSError):
            os.unlink(args.apply_verdicts)
        return 0

    if args.judge_backlog is not None:
        rows = db.execute(
            """SELECT l.id, l.outcode, l.price, l.bedrooms, l.kind, l.tenure,
                      l.title, l.url, l.description, l.key_info
               FROM listings l
               LEFT JOIN verdicts v ON v.id = l.id
               WHERE v.id IS NULL AND l.status != 'withdrawn'
               ORDER BY l.id LIMIT ?""",
            (args.judge_backlog,),
        ).fetchall()
        print(
            # Keep `.keys()`: iterating a sqlite3.Row yields VALUES, not column
            # names, so SIM118's "simplification" silently keys the dict by data.
            json.dumps(
                [{k: r[k] for k in r.keys()} for r in rows],  # noqa: SIM118
                indent=1,
            ),
            file=sys.stderr,
        )
        return 0

    if args.backfill is not None:
        n = backfill(db, src, args.backfill, log)
        export(db, os.path.join(args.state, "data", "listings.json"))
        # stderr, never stdout: a backfill must not look like something moving.
        print(f"backfilled {n} listings", file=sys.stderr)
        return 0

    try:
        seen = sweep(db, cfg, today, log, src)
    except FetchFailed as e:
        # Unknown state, not an empty market. Say so on stderr -- which hermes
        # surfaces as a failure -- and leave stdout untouched so the hash is
        # unchanged and nothing is reported as having moved.
        print(f"fetch failed, nothing recorded: {e}", file=sys.stderr)
        return 2

    first_run = db.execute("SELECT COUNT(*) c FROM listings").fetchone()["c"] == 0
    # On a bootstrap the WHOLE corpus is new, and none of it is reported, so
    # fetching prose nobody will read would be hundreds of requests spent on
    # silence. `--backfill` fills it afterwards, at a pace the operator chooses.
    delta = record(db, seen, today, None if (first_run or args.bootstrap) else src, log)
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
