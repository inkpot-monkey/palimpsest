#!/usr/bin/env python3
"""Tests for the property board (property#5).

The board is the reading surface over the database the property-watch job
writes. Its whole contract with the job is "one writer per table": the job owns
`listings`, `observations` and `sweeps`; the board owns `favourites` and
nothing else. Most of what can go wrong here is therefore not "does the page
render" but "does the board stay inside its half of the database", so that is
what these tests hold.

Five seams:

  1. `connect(path)` -- the shared-database handshake. WAL, a busy timeout, a
     group-writable file, and the creation of `favourites` AND NO OTHER TABLE.
     Two processes write this file; the hygiene is load-bearing, not decoration.
  2. `listings(db)` -- the read model the map and the table are both drawn from.
  3. `history(db, id)` -- price over time for one listing.
  4. `favourite()` / `unfavourite()` -- the board's only write.
  5. The HTTP surface, driven over a real socket against a temp database, which
     is the only seam that proves the three above are actually reachable.

Nothing here reaches the network beyond loopback.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sqlite3
import stat
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "property_board", Path(__file__).with_name("property-board.py")
)
board = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(board)


# The job's schema, copied verbatim from property-watch.py. Copied and not
# imported on purpose: these tests must fail if the board starts depending on a
# column the job does not actually write, and importing the job's SCHEMA would
# hide exactly that by construction.
JOB_SCHEMA = """
CREATE TABLE IF NOT EXISTS listings (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  outcode TEXT NOT NULL,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  absences INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'live',
  first_price INTEGER,
  price INTEGER,
  bedrooms INTEGER, bathrooms INTEGER,
  title TEXT, address TEXT, kind TEXT,
  tenure TEXT, lease_years INTEGER,
  auction_agent INTEGER DEFAULT 0,
  agent TEXT, lat REAL, lon REAL, url TEXT,
  features TEXT,
  raw TEXT,
  score INTEGER, verdict TEXT,
  relist_of TEXT
);
CREATE TABLE IF NOT EXISTS observations (
  id TEXT NOT NULL, seen_on TEXT NOT NULL,
  price INTEGER, status TEXT,
  PRIMARY KEY (id, seen_on)
);
CREATE TABLE IF NOT EXISTS sweeps (
  outcode TEXT NOT NULL, seen_on TEXT NOT NULL, total INTEGER, kept INTEGER,
  PRIMARY KEY (outcode, seen_on)
);
"""


def listing(db: sqlite3.Connection, lid: str, **over) -> None:
    row = {
        "id": lid,
        "source": "onthemarket",
        "outcode": "SE15",
        "first_seen": "2026-11-01",
        "last_seen": "2026-11-17",
        "absences": 0,
        "status": "live",
        "first_price": 500000,
        "price": 475000,
        "bedrooms": 2,
        "bathrooms": 1,
        "title": "Two bedroom maisonette",
        "address": "Bellenden Road, SE15",
        "kind": "maisonette",
        "tenure": "share_of_freehold",
        "lease_years": None,
        "auction_agent": 0,
        "agent": "Some Agent",
        "lat": 51.4661,
        "lon": -0.0712,
        "url": "https://www.onthemarket.com/details/" + lid,
        "features": None,
        "raw": "{}",
        "score": 8,
        "verdict": "Garden, share of freehold, under budget.",
        "relist_of": None,
    }
    row.update(over)
    cols = ",".join(row)
    marks = ",".join("?" * len(row))
    db.execute(f"INSERT INTO listings ({cols}) VALUES ({marks})", list(row.values()))
    db.commit()


def seeded(path: str) -> sqlite3.Connection:
    """A database shaped the way the job leaves it."""
    db = sqlite3.connect(path)
    db.row_factory = sqlite3.Row
    db.executescript(JOB_SCHEMA)
    return db


class TestConnect(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "property-watch.db")
        self.addCleanup(self.dir.cleanup)

    def test_creates_favourites_and_no_other_table(self):
        # The contract with the job is one writer per table. If the board ever
        # creates `listings`, a board started before the job's first sweep would
        # leave an empty table the job then fills -- but a schema drift between
        # the two would surface as silently missing columns rather than a loud
        # error, and the job would be reading a table it did not define.
        db = board.connect(self.path)
        names = {
            r[0]
            for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        self.assertEqual({"favourites"}, names)

    def test_leaves_the_jobs_tables_alone(self):
        seeded(self.path).close()
        db = board.connect(self.path)
        names = {
            r[0]
            for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        self.assertEqual({"listings", "observations", "sweeps", "favourites"}, names)

    def test_wal_and_a_busy_timeout(self):
        # Two processes write this file -- the job at 07:30, the board whenever
        # someone clicks. Without WAL a reader blocks the writer outright; without
        # a busy timeout the loser of a race gets SQLITE_BUSY immediately instead
        # of waiting the moment or two the other write takes.
        db = board.connect(self.path)
        self.assertEqual("wal", db.execute("PRAGMA journal_mode").fetchone()[0])
        self.assertGreaterEqual(db.execute("PRAGMA busy_timeout").fetchone()[0], 5000)

    def test_the_database_file_is_group_writable(self):
        # The job and the board are different users sharing one file through the
        # `property-watch` group (gid 973). sqlite creates it under the process
        # umask, which on this fleet is 022 -- so the file lands 644 and the
        # board's first write to `favourites` fails however the directory is set
        # up. Whichever of the two opens it first must fix that.
        db = board.connect(self.path)
        db.close()
        mode = stat.S_IMODE(os.stat(self.path).st_mode)
        self.assertTrue(mode & stat.S_IWGRP, oct(mode))

    def test_repairs_a_file_that_is_already_644(self):
        # The live database predates this fix, so creating it correctly is not
        # enough: the existing one has to be repaired on open.
        seeded(self.path).close()
        os.chmod(self.path, 0o644)
        board.connect(self.path).close()
        self.assertTrue(stat.S_IMODE(os.stat(self.path).st_mode) & stat.S_IWGRP)

    def test_the_wal_sidecars_are_group_writable_too(self):
        # A writer needs write on `-wal` and `-shm`, not just the database. They
        # are created by sqlite under the same umask, so fixing only the main
        # file leaves the second process locked out in a way that reads as
        # "unable to open database file" and looks like the sandbox trap.
        db = board.connect(self.path)
        db.execute("INSERT INTO favourites (id, added_on) VALUES ('x', '2026-11-17')")
        db.commit()
        wal = self.path + "-wal"
        self.assertTrue(os.path.exists(wal))
        self.assertTrue(stat.S_IMODE(os.stat(wal).st_mode) & stat.S_IWGRP)


class TestTheJobAgrees(unittest.TestCase):
    """The other half of the shared-file handshake.

    Tested from here, and from here only, because it is not a property of
    either program alone: it is the agreement between them. The job creates the
    database first (it has been running since before the board existed), so if
    ITS connect() leaves the file 0644 the board cannot write `favourites`
    however carefully the board's own connect() is written.
    """

    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "property_watch", Path(__file__).with_name("property-watch.py")
        )
        self.job = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.job)
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "property-watch.db")

    def test_the_job_leaves_the_database_group_writable(self):
        db = self.job.connect(self.path)
        db.close()
        mode = stat.S_IMODE(os.stat(self.path).st_mode)
        self.assertTrue(mode & stat.S_IWGRP, oct(mode))

    def test_the_job_repairs_a_file_that_is_already_644(self):
        self.job.connect(self.path).close()
        os.chmod(self.path, 0o644)
        self.job.connect(self.path).close()
        self.assertTrue(stat.S_IMODE(os.stat(self.path).st_mode) & stat.S_IWGRP)

    def test_the_job_leaves_the_wal_sidecars_group_writable(self):
        db = self.job.connect(self.path)
        db.execute("INSERT INTO favourites (id, added_on) VALUES ('x', '2026-11-17')")
        db.commit()
        self.assertTrue(
            stat.S_IMODE(os.stat(self.path + "-wal").st_mode) & stat.S_IWGRP
        )


class TestReadModel(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "db")
        seeded(self.path).close()
        self.db = board.connect(self.path)

    def test_carries_the_fields_the_board_shows(self):
        listing(self.db, "a1")
        (row,) = board.listings(self.db)
        self.assertEqual("a1", row["id"])
        self.assertEqual(475000, row["price"])
        self.assertEqual(500000, row["first_price"])
        self.assertEqual("2026-11-01", row["first_seen"])
        self.assertEqual("live", row["status"])
        self.assertEqual("share_of_freehold", row["tenure"])
        self.assertEqual(2, row["bedrooms"])
        self.assertEqual(8, row["score"])
        self.assertEqual("Garden, share of freehold, under budget.", row["verdict"])
        self.assertEqual(51.4661, row["lat"])

    def test_days_on_market_is_measured_from_first_seen_to_last_seen(self):
        # Not "to today": a withdrawn listing's clock stopped when it withdrew,
        # and counting to today would show it ageing forever.
        listing(self.db, "a1", first_seen="2026-10-18", last_seen="2026-11-17")
        (row,) = board.listings(self.db)
        self.assertEqual(30, row["days_on_market"])

    def test_the_price_drop_is_original_minus_current(self):
        listing(self.db, "a1", first_price=525000, price=499950)
        (row,) = board.listings(self.db)
        self.assertEqual(25050, row["price_drop"])

    def test_no_drop_when_the_price_never_moved(self):
        listing(self.db, "a1", first_price=500000, price=500000)
        (row,) = board.listings(self.db)
        self.assertEqual(0, row["price_drop"])

    def test_a_listing_without_coordinates_is_kept_but_unmappable(self):
        # Dropping it would hide it from the operator as well as from the map,
        # which is the same mistake the job refuses to make with missing tenure.
        listing(self.db, "a1", lat=None, lon=None)
        (row,) = board.listings(self.db)
        self.assertIsNone(row["lat"])
        self.assertFalse(row["mappable"])

    def test_a_favourited_listing_says_so(self):
        listing(self.db, "a1")
        listing(self.db, "a2")
        board.favourite(self.db, "a1", "near the park")
        by_id = {r["id"]: r for r in board.listings(self.db)}
        self.assertTrue(by_id["a1"]["favourite"])
        self.assertEqual("near the park", by_id["a1"]["note"])
        self.assertFalse(by_id["a2"]["favourite"])

    def test_json_serialisable(self):
        # The read model goes straight out of the HTTP surface, so a sqlite3.Row
        # leaking through would be a 500 and not a test failure.
        listing(self.db, "a1")
        json.dumps(board.listings(self.db))


class TestHistory(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "db")
        seeded(self.path).close()
        self.db = board.connect(self.path)

    def test_price_over_time_in_date_order(self):
        listing(self.db, "a1")
        for day, price in [
            ("2026-11-03", 500000),
            ("2026-11-01", 525000),
            ("2026-11-10", 475000),
        ]:
            self.db.execute(
                "INSERT INTO observations (id, seen_on, price, status)"
                " VALUES (?,?,?, 'live')",
                (day and "a1", day, price),
            )
        self.db.commit()
        self.assertEqual(
            [
                {"seen_on": "2026-11-01", "price": 525000, "status": "live"},
                {"seen_on": "2026-11-03", "price": 500000, "status": "live"},
                {"seen_on": "2026-11-10", "price": 475000, "status": "live"},
            ],
            board.history(self.db, "a1"),
        )

    def test_only_that_listing(self):
        listing(self.db, "a1")
        listing(self.db, "a2")
        self.db.executemany(
            "INSERT INTO observations (id, seen_on, price, status) VALUES (?,?,?, 'live')",
            [("a1", "2026-11-01", 1), ("a2", "2026-11-01", 2)],
        )
        self.db.commit()
        self.assertEqual([1], [o["price"] for o in board.history(self.db, "a1")])


class TestFavourites(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "db")
        seeded(self.path).close()
        self.db = board.connect(self.path)
        listing(self.db, "a1")

    def test_a_favourite_persists_across_connections(self):
        board.favourite(self.db, "a1", "garden")
        self.db.close()
        again = board.connect(self.path)
        self.assertEqual(
            [("a1", "garden")],
            [tuple(r) for r in again.execute("SELECT id, note FROM favourites")],
        )

    def test_refavouriting_updates_the_note_rather_than_erroring(self):
        board.favourite(self.db, "a1", "garden")
        board.favourite(self.db, "a1", "garden, and a shed")
        rows = [tuple(r) for r in self.db.execute("SELECT id, note FROM favourites")]
        self.assertEqual([("a1", "garden, and a shed")], rows)

    def test_unfavouriting_removes_the_row(self):
        board.favourite(self.db, "a1", None)
        board.unfavourite(self.db, "a1")
        self.assertEqual([], list(self.db.execute("SELECT id FROM favourites")))

    def test_unfavouriting_something_that_was_never_favourited_is_quiet(self):
        board.unfavourite(self.db, "nope")

    def test_favouriting_touches_no_other_table(self):
        # The one-writer-per-table contract, asserted rather than assumed. If this
        # ever fails, the job and the board are both writing the same rows and the
        # loser's work disappears without a trace.
        before = self.db.execute("SELECT * FROM listings").fetchall()
        board.favourite(self.db, "a1", "x")
        after = self.db.execute("SELECT * FROM listings").fetchall()
        self.assertEqual([tuple(r) for r in before], [tuple(r) for r in after])
        self.assertEqual([], list(self.db.execute("SELECT * FROM observations")))


class TestHttp(unittest.TestCase):
    """The surface as the browser sees it, over a real socket."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "db")
        seeded(self.path).close()
        db = board.connect(self.path)
        listing(db, "a1", title="Two bed with a garden")
        db.execute(
            "INSERT INTO observations (id, seen_on, price, status)"
            " VALUES ('a1', '2026-11-01', 500000, 'live')"
        )
        db.commit()
        db.close()

        self.server = board.make_server("127.0.0.1", 0, self.path)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        t = threading.Thread(target=self.server.serve_forever, daemon=True)
        t.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def get(self, path):
        with urllib.request.urlopen(self.base + path) as r:
            return r.status, r.read()

    def send(self, method, path, body=None):
        req = urllib.request.Request(
            self.base + path,
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json"} if body is not None else {},
        )
        with urllib.request.urlopen(req) as r:
            return r.status, r.read()

    def test_the_page_is_served_at_the_root(self):
        status, body = self.get("/")
        self.assertEqual(200, status)
        self.assertIn(b"<html", body.lower())

    def test_the_page_warns_that_a_pin_is_not_an_address(self):
        # Asked for explicitly by property#5: portals fuzz exact location, so a
        # pin is street-level. Someone acting on a pin as if it were a front door
        # is the one way this page can mislead, so the warning is a test.
        _, body = self.get("/")
        self.assertIn(b"street", body.lower())
        self.assertIn(b"not", body.lower())

    def test_listings_api_returns_the_read_model(self):
        status, body = self.get("/api/listings")
        self.assertEqual(200, status)
        rows = json.loads(body)
        self.assertEqual(1, len(rows))
        self.assertEqual("Two bed with a garden", rows[0]["title"])
        self.assertEqual(8, rows[0]["score"])

    def test_history_api(self):
        status, body = self.get("/api/listings/a1/history")
        self.assertEqual(200, status)
        self.assertEqual(500000, json.loads(body)[0]["price"])

    def test_favouriting_over_http_persists_a_row(self):
        status, _ = self.send("POST", "/api/favourites", {"id": "a1", "note": "shed"})
        self.assertEqual(200, status)
        db = sqlite3.connect(self.path)
        self.assertEqual(
            [("a1", "shed")], list(db.execute("SELECT id, note FROM favourites"))
        )
        db.close()
        rows = json.loads(self.get("/api/listings")[1])
        self.assertTrue(rows[0]["favourite"])

    def test_unfavouriting_over_http(self):
        self.send("POST", "/api/favourites", {"id": "a1", "note": None})
        self.send("DELETE", "/api/favourites/a1")
        rows = json.loads(self.get("/api/listings")[1])
        self.assertFalse(rows[0]["favourite"])

    def test_favouriting_an_unknown_listing_is_refused(self):
        # The job reads this table to tell you when something you favourited goes
        # under offer. A row pointing at no listing is a row it can never resolve.
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.send("POST", "/api/favourites", {"id": "ghost"})
        self.assertEqual(404, e.exception.code)

    def test_an_unknown_path_is_a_404_not_a_traceback(self):
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.get("/api/nope")
        self.assertEqual(404, e.exception.code)

    def test_the_only_writable_surface_is_favourites(self):
        # There is no endpoint that can touch the job's tables. Asserted here
        # because the contract is the reason this app is as small as it is.
        for method, path in [
            ("POST", "/api/listings"),
            ("DELETE", "/api/listings/a1"),
            ("POST", "/api/observations"),
        ]:
            with self.assertRaises(urllib.error.HTTPError, msg=path) as e:
                self.send(method, path, {})
            self.assertIn(e.exception.code, (404, 405))


class TestHttpUnderAPathPrefix(unittest.TestCase):
    """The board served at `boards.<domain>/property` rather than its own name.

    property#8 moved every board behind one shared, path-routed vhost. Caddy
    does NOT strip the prefix -- the app is told what the prefix is and owns
    the whole URL space, so what the browser asks for is exactly what this
    process sees. The alternative (`handle_path`, which strips) would leave the
    app emitting links into a URL space it cannot see; it would still need to
    be told the prefix in order to emit them, so stripping buys nothing and
    adds a second coordinate system to debug.
    """

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "db")
        seeded(self.path).close()
        db = board.connect(self.path)
        listing(db, "a1", title="Two bed with a garden")
        db.execute(
            "INSERT INTO observations (id, seen_on, price, status)"
            " VALUES ('a1', '2026-11-01', 500000, 'live')"
        )
        db.commit()
        db.close()

        self.server = board.make_server("127.0.0.1", 0, self.path, "/property")
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def get(self, path):
        with urllib.request.urlopen(self.base + path) as r:
            return r.status, r.read()

    def send(self, method, path, body=None):
        req = urllib.request.Request(
            self.base + path,
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Content-Type": "application/json"} if body is not None else {},
        )
        with urllib.request.urlopen(req) as r:
            return r.status, r.read()

    def test_the_page_is_served_under_the_prefix(self):
        # Both spellings, because a human types the one without the slash and
        # Caddy forwards it verbatim.
        self.assertEqual(200, self.get("/property/")[0])
        self.assertEqual(200, self.get("/property")[0])

    def test_the_api_is_served_under_the_prefix(self):
        status, body = self.get("/property/api/listings")
        self.assertEqual(200, status)
        self.assertEqual("Two bed with a garden", json.loads(body)[0]["title"])

    def test_history_is_served_under_the_prefix(self):
        status, body = self.get("/property/api/listings/a1/history")
        self.assertEqual(200, status)
        self.assertEqual(500000, json.loads(body)[0]["price"])

    def test_the_probe_endpoint_is_served_under_the_prefix(self):
        # property#8 gives each board its own uptime probe, and the probe is a
        # GET at this path. A probe on the vhost root proves Caddy and the
        # cert; only this one proves the board behind the prefix is alive.
        status, body = self.get("/property/healthz")
        self.assertEqual(200, status)
        self.assertTrue(json.loads(body)["ok"])

    def test_the_page_emits_its_links_under_the_prefix(self):
        # This is what "a board tolerates being served under a prefix" means,
        # and it is the whole cost property#8 accepted. A page that fetches
        # `/api/listings` from `boards.<domain>/property` is asking the VHOST
        # ROOT for an API that is not there, and renders empty with no error.
        _, body = self.get("/property/")
        self.assertIn(b'"/property"', body)
        self.assertNotIn(b'fetch("/api/', body)

    def test_the_unprefixed_paths_are_gone(self):
        # Not merely an extra alias. The prefix IS the app's URL space once it
        # has one: if both answered, a link could be emitted into either and
        # only one of the two works through Caddy.
        for path in ("/", "/api/listings", "/healthz"):
            with self.assertRaises(urllib.error.HTTPError, msg=path) as e:
                self.get(path)
            self.assertEqual(404, e.exception.code)

    def test_favouriting_round_trips_under_the_prefix(self):
        # The board's only write, through the prefix, both ways.
        self.assertEqual(
            200, self.send("POST", "/property/api/favourites", {"id": "a1"})[0]
        )
        rows = json.loads(self.get("/property/api/listings")[1])
        self.assertTrue(rows[0]["favourite"])

        self.assertEqual(200, self.send("DELETE", "/property/api/favourites/a1")[0])
        rows = json.loads(self.get("/property/api/listings")[1])
        self.assertFalse(rows[0]["favourite"])


if __name__ == "__main__":
    unittest.main()
