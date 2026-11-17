#!/usr/bin/env python3
"""Tests for the deterministic half of the property-watch job.

Three seams, and only three:

  1. `OnTheMarket.parse_detail(html)` -- a detail page's bytes in, the listing's
     prose and the portal's own key-info facts out. This is where the whole
     feature lives, and it is pure, so it is tested with fixtures shaped like
     the real page rather than over the network.
  2. The detail-fetch POLICY, through `record()` -- which listings get fetched,
     how many, and what happens to a listing whose detail page fails. Tested
     through a fake source so the request volume is observable, because
     "single-digit extra requests a day" is a promise to OnTheMarket and not an
     implementation detail.
  3. `digest()` -- stable bytes. Two runs on an unchanged world print the same
     thing, and a quiet day prints nothing. This is what stops the model being
     woken every morning, so a test that can catch it regressing is worth more
     than the rest put together.

Nothing here reaches the network.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "property_watch", Path(__file__).with_name("property-watch.py")
)
pw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pw)


def detail_page(description: str, key_info: list[dict] | None = None) -> str:
    """A detail page of the real shape: Next.js, with the property in its blob.

    The surrounding page is 238 KB of markup and ads on the real site; what
    matters to the parser is that the payload is a <script id="__NEXT_DATA__">
    containing props.pageProps.initialReduxState.property, so that is what the
    fixture reproduces. Key names and nesting are verbatim from a live fetch of
    onthemarket.com/details/20123627/.
    """
    blob = {
        "props": {
            "pageProps": {
                "initialReduxState": {
                    "property": {
                        "id": 20123627,
                        "description": description,
                        "keyInfo": key_info if key_info is not None else [],
                    }
                }
            }
        }
    }
    return (
        "<html><body><div>marketing</div>"
        '<script id="__NEXT_DATA__" type="application/json" crossorigin="anonymous">'
        + json.dumps(blob)
        + "</script></body></html>"
    )


class ParseDetail(unittest.TestCase):
    def test_description_arrives_as_readable_text(self):
        """The portal stores the prose as markup; the model is handed text.

        Verbatim means nothing is summarised, dropped or interpreted -- not that
        `<br/>` is passed through to something that will never render it.
        """
        html = detail_page(
            "<br/><b>SUMMARY</b><br/>Two-bedroom flat, <b>NO ONWARD CHAIN</b>"
            "<br/><br/>Service charge &pound;1,450 per annum &amp; share of freehold."
        )
        d = pw.OnTheMarket.parse_detail(html)
        self.assertEqual(
            d["description"],
            "SUMMARY\n"
            "Two-bedroom flat, NO ONWARD CHAIN\n\n"
            "Service charge £1,450 per annum & share of freehold.",
        )

    def test_key_info_is_copied_verbatim_not_interpreted(self):
        """The portal publishes service charge as a FIELD, not only as prose.

        It is copied across untouched: "£697 per annum" stays a string. Turning
        it into 697 is the judgement this job assigns to the model, and a parser
        that got it wrong would be believed.
        """
        d = pw.OnTheMarket.parse_detail(
            detail_page(
                "prose",
                [
                    {
                        "title": "Tenure",
                        "iconId": "gavel",
                        "value": "Share of freehold",
                    },
                    {
                        "title": "Service charge",
                        "iconId": "trees",
                        "value": "£697 per annum",
                    },
                    {
                        "title": "Mobile signal",
                        "isMobileSignal": True,
                        "data": {"ee": "green"},
                    },
                ],
            )
        )
        self.assertEqual(
            d["key_info"],
            {"Tenure": "Share of freehold", "Service charge": "£697 per annum"},
        )

    def test_a_page_with_no_payload_yields_nothing_rather_than_raising(self):
        """A redesign, a holding page or a 404 body must not end the sweep."""
        d = pw.OnTheMarket.parse_detail(
            "<html><body>Sorry, page not found</body></html>"
        )
        self.assertEqual(d, {"description": None, "key_info": {}})

    def test_a_truncated_payload_yields_nothing_rather_than_raising(self):
        html = detail_page("prose")[: len(detail_page("prose")) // 2]
        d = pw.OnTheMarket.parse_detail(html)
        self.assertEqual(d, {"description": None, "key_info": {}})


# ---------------------------------------------------------------------------
# Seam 2: the fetch policy, observed through record()
# ---------------------------------------------------------------------------


class FakeSource:
    """Records every detail fetch so request volume is assertable."""

    name = "onthemarket"

    def __init__(self, fail: set[str] | None = None):
        self.fetched: list[str] = []
        self.fail = fail or set()

    def detail(self, url: str) -> dict:
        self.fetched.append(url)
        if url in self.fail:
            raise pw.urllib.error.URLError("boom")
        return {
            "description": f"prose for {url}",
            "key_info": {"Service charge": "£800 per annum"},
        }


def listing(pid: str, **over) -> dict:
    r = {
        "id": f"otm:{pid}",
        "source": "onthemarket",
        "outcode": "SE15",
        "price": 400000,
        "price_qualifier": None,
        "bedrooms": 2,
        "bathrooms": 1,
        "title": "2 bed flat",
        "address": "1 Somewhere Road",
        "kind": "flat",
        "tenure": "share_of_freehold",
        "lease_years": None,
        "auction": False,
        "auction_agent": False,
        "shared_ownership": False,
        "agent": "An Agent",
        "lat": 51.0,
        "lon": -0.07,
        "url": f"https://www.onthemarket.com/details/{pid}/",
        "features": ["Two Bedroom"],
        "raw": {"id": pid},
    }
    r.update(over)
    return r


class FetchPolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = pw.connect(os.path.join(self.tmp.name, "t.db"))
        self.addCleanup(self.tmp.cleanup)

    def test_only_newly_seen_listings_are_fetched(self):
        """The corpus is ~275 and a day's delta is a handful.

        Re-fetching the whole corpus daily would be 275 requests against the ~60
        the sweep already makes, which is not the bargain struck in property#1.
        """
        src = FakeSource()
        seen = {r["id"]: r for r in (listing("1"), listing("2"))}
        pw.record(self.db, seen, "2026-11-17", src)
        self.assertEqual(len(src.fetched), 2)

        seen["otm:3"] = listing("3")
        pw.record(self.db, seen, "2026-11-18", src)
        self.assertEqual(src.fetched[2:], ["https://www.onthemarket.com/details/3/"])

    def test_a_run_cannot_exceed_the_per_run_fetch_budget(self):
        """A portal glitch that makes every id look new must not become a storm."""
        src = FakeSource()
        seen = {
            r["id"]: r for r in (listing(str(i)) for i in range(pw.DETAIL_BUDGET + 5))
        }
        pw.record(self.db, seen, "2026-11-17", src)
        self.assertEqual(len(src.fetched), pw.DETAIL_BUDGET)
        # ...and every listing is still recorded. The budget bounds the prose,
        # never the corpus.
        self.assertEqual(
            self.db.execute("SELECT COUNT(*) c FROM listings").fetchone()["c"],
            pw.DETAIL_BUDGET + 5,
        )

    def test_a_failed_detail_fetch_keeps_the_listing(self):
        """Losing a listing because its description 500'd would be the worst
        outcome available: the listing would read as never having existed, and
        three runs later as withdrawn."""
        src = FakeSource(fail={"https://www.onthemarket.com/details/2/"})
        seen = {r["id"]: r for r in (listing("1"), listing("2"))}
        pw.record(self.db, seen, "2026-11-17", src)

        rows = {
            r["id"]: r for r in self.db.execute("SELECT id,description FROM listings")
        }
        self.assertEqual(set(rows), {"otm:1", "otm:2"})
        self.assertIsNone(rows["otm:2"]["description"])
        self.assertEqual(
            rows["otm:1"]["description"], "prose for " + listing("1")["url"]
        )

    def test_the_description_reaches_the_model(self):
        """Stored and never read would be the whole ticket, unfixed."""
        src = FakeSource()
        pw.record(self.db, {"otm:1": listing("1")}, "2026-11-17", src)
        out = os.path.join(self.tmp.name, "listings.json")
        pw.export(self.db, out)
        with open(out) as f:
            rows = json.load(f)
        self.assertEqual(rows[0]["description"], "prose for " + listing("1")["url"])
        self.assertEqual(
            json.loads(rows[0]["key_info"]), {"Service charge": "£800 per annum"}
        )


# ---------------------------------------------------------------------------
# Seam 3: stable bytes
# ---------------------------------------------------------------------------


class StableBytes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = pw.connect(os.path.join(self.tmp.name, "t.db"))
        self.addCleanup(self.tmp.cleanup)

    def test_an_unchanged_world_prints_nothing_twice(self):
        src = FakeSource()
        seen = {r["id"]: r for r in (listing("1"), listing("2"))}
        pw.record(self.db, seen, "2026-11-17", src)  # bootstrap

        a = pw.digest(pw.record(self.db, seen, "2026-11-18", src), set())
        b = pw.digest(pw.record(self.db, seen, "2026-11-19", src), set())
        self.assertEqual(a, "")
        self.assertEqual(b, "")

    def test_a_days_delta_is_byte_identical_when_replayed(self):
        """Same world, same bytes -- including the new prose."""
        seen = {"otm:1": listing("1")}
        a = pw.digest(pw.record(self.db, dict(seen), "2026-11-17", FakeSource()), set())

        db2 = pw.connect(os.path.join(self.tmp.name, "u.db"))
        b = pw.digest(pw.record(db2, dict(seen), "2026-11-17", FakeSource()), set())
        self.assertEqual(a, b)

    def test_a_new_listings_prose_is_put_in_front_of_the_model(self):
        """The digest IS the prompt. A description that only lands in the
        database is one the model has to be told to go and read, and the first
        real run showed it will not."""
        src = FakeSource()
        d = pw.record(self.db, {"otm:1": listing("1")}, "2026-11-17", src)
        text = pw.digest(d, set())
        self.assertIn("prose for https://www.onthemarket.com/details/1/", text)
        self.assertIn("Service charge: £800 per annum", text)


# ---------------------------------------------------------------------------
# Seam 4: applying verdicts (property#7)
#
# The model writes JSON and calls the script; the script owns every write. So
# this seam is the enforcement: what the model says versus what is allowed to
# reach the corpus. Nothing here can test whether the model emits GOOD JSON --
# only what happens to the JSON it does emit.
# ---------------------------------------------------------------------------


class ApplyVerdicts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = pw.connect(os.path.join(self.tmp.name, "t.db"))
        self.db.execute(
            """INSERT INTO listings(id,source,outcode,first_seen,last_seen,price,kind)
               VALUES ('otm:1','onthemarket','SE15','2026-11-01','2026-11-17',500000,'flat')"""
        )
        self.db.commit()
        self.addCleanup(self.tmp.cleanup)

    def test_a_verdict_is_stored_with_the_price_it_judged(self):
        """A verdict without its price is an opinion about an unknown number.
        Denormalised deliberately: joining back through `observations` goes
        ambiguous the moment a listing is withdrawn and re-listed."""
        applied, rejected = pw.apply_verdicts(
            self.db,
            [{"id": "otm:1", "verdict": "garden backs onto the railway"}],
            "2026-11-17",
            model="haiku-5.5",
            reasoning_effort="low",
        )
        self.assertEqual((applied, rejected), (1, []))
        row = self.db.execute("SELECT * FROM verdicts").fetchone()
        self.assertEqual(row["verdict"], "garden backs onto the railway")
        self.assertEqual(row["price_at_judgement"], 500000)
        self.assertEqual(row["model"], "haiku-5.5")
        self.assertEqual(row["reasoning_effort"], "low")

    def test_a_bad_row_is_rejected_without_costing_the_good_ones(self):
        """One malformed entry must not throw away a night's judgement, and a
        rejection must say which row and why -- a count alone is not actionable."""
        applied, rejected = pw.apply_verdicts(
            self.db,
            [
                {"id": "otm:1", "verdict": "fine"},
                {"id": "otm:nope", "verdict": "invented listing"},
                {"id": "otm:1"},
                {"verdict": "no id at all"},
                "not an object",
            ],
            "2026-11-17",
        )
        self.assertEqual(applied, 1)
        self.assertEqual(len(rejected), 4)
        self.assertTrue(any("unknown listing" in r for r in rejected))
        self.assertEqual(
            self.db.execute("SELECT COUNT(*) c FROM verdicts").fetchone()["c"], 1
        )

    def test_a_payload_that_is_not_a_list_is_refused_whole(self):
        applied, rejected = pw.apply_verdicts(self.db, {"id": "otm:1"}, "2026-11-17")
        self.assertEqual(applied, 0)
        self.assertEqual(len(rejected), 1)

    def test_judging_twice_in_a_day_replaces_rather_than_duplicates(self):
        """A catch-up run, or an operator triggering the job by hand, must not
        leave two verdicts for one day with no way to say which is current."""
        pw.apply_verdicts(self.db, [{"id": "otm:1", "verdict": "first"}], "2026-11-17")
        pw.apply_verdicts(self.db, [{"id": "otm:1", "verdict": "second"}], "2026-11-17")
        rows = self.db.execute("SELECT verdict FROM verdicts").fetchall()
        self.assertEqual([r["verdict"] for r in rows], ["second"])

    def test_two_days_are_two_verdicts(self):
        """The point of the table: what the agent thought before and after a
        price moved is the record, and one row per listing would destroy it."""
        pw.apply_verdicts(
            self.db, [{"id": "otm:1", "verdict": "at 500k"}], "2026-11-17"
        )
        self.db.execute("UPDATE listings SET price=460000 WHERE id='otm:1'")
        pw.apply_verdicts(
            self.db, [{"id": "otm:1", "verdict": "at 460k"}], "2026-11-18"
        )
        rows = self.db.execute(
            "SELECT judged_on, price_at_judgement FROM verdicts ORDER BY judged_on"
        ).fetchall()
        self.assertEqual(
            [(r["judged_on"], r["price_at_judgement"]) for r in rows],
            [("2026-11-17", 500000), ("2026-11-18", 460000)],
        )

    def test_the_trigger_is_stamped_by_us_not_supplied_by_the_model(self):
        """The script knows why a listing was in the delta as a fact. Asking the
        model would mean telling it, and it could then get it wrong."""
        applied, _ = pw.apply_verdicts(
            self.db,
            [{"id": "otm:1", "verdict": "cheaper now", "trigger": "LIES"}],
            "2026-11-17",
            triggers={"otm:1": "reduced"},
        )
        self.assertEqual(applied, 1)
        row = self.db.execute("SELECT trigger FROM verdicts").fetchone()
        self.assertEqual(row["trigger"], "reduced")


# ---------------------------------------------------------------------------
# Seam 5: opening a database that predates this change
#
# The live corpus on rk1b exists and has hundreds of rows in it. property#6
# already learned what happens when a schema change assumes a fresh file:
# `CREATE TABLE IF NOT EXISTS` does nothing to a table that is already there, so
# the first run after a deploy dies on "no such column" -- AFTER a full sweep,
# because the sweep comes first. This seam is that lesson, kept.
# ---------------------------------------------------------------------------


class OpeningAnOlderDatabase(unittest.TestCase):
    PRE_7 = """
    CREATE TABLE listings (
      id TEXT PRIMARY KEY, source TEXT NOT NULL, outcode TEXT NOT NULL,
      first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
      absences INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'live',
      first_price INTEGER, price INTEGER, bedrooms INTEGER, bathrooms INTEGER,
      title TEXT, address TEXT, kind TEXT, tenure TEXT, lease_years INTEGER,
      auction_agent INTEGER DEFAULT 0, agent TEXT, lat REAL, lon REAL, url TEXT,
      features TEXT, description TEXT, key_info TEXT, raw TEXT,
      score INTEGER, verdict TEXT,
      relist_of TEXT
    );
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "old.db")
        old = sqlite3.connect(self.path)
        old.executescript(self.PRE_7)
        old.execute(
            "INSERT INTO listings(id,source,outcode,first_seen,last_seen,price,score)"
            " VALUES ('otm:1','onthemarket','SE15','2026-11-01','2026-11-17',500000,7)"
        )
        old.commit()
        old.close()
        self.addCleanup(self.tmp.cleanup)

    def test_the_verdicts_table_is_created_on_an_existing_corpus(self):
        db = pw.connect(self.path)
        db.execute("SELECT * FROM verdicts")  # raises if the migration did not run

    def test_the_dead_score_column_is_removed_and_the_corpus_survives(self):
        """A column that exists and is always NULL reads as 'the model did not
        judge this one', which is a different and wrong statement."""
        db = pw.connect(self.path)
        cols = {r["name"] for r in db.execute("PRAGMA table_info(listings)")}
        self.assertNotIn("score", cols)
        row = db.execute("SELECT id, price FROM listings").fetchone()
        self.assertEqual((row["id"], row["price"]), ("otm:1", 500000))

    def test_opening_twice_is_harmless(self):
        pw.connect(self.path).close()
        db = pw.connect(self.path)
        self.assertNotIn(
            "score", {r["name"] for r in db.execute("PRAGMA table_info(listings)")}
        )


# ---------------------------------------------------------------------------
# Seam 6: the --apply-verdicts CLI contract
#
# THE MONITOR HASH IS THE JOB'S WHOLE ECONOMY. `--monitor-script` hashes stdout
# exactly: if applying verdicts ever writes a single byte there, the hash changes
# every run, the model is woken every morning forever, and NOTHING LOOKS BROKEN
# -- the job still works, it just quietly costs a model call a day. That is the
# kind of regression a test has to catch because a human never will.
# ---------------------------------------------------------------------------


class ApplyVerdictsCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = self.tmp.name
        os.makedirs(os.path.join(self.state, "data"), exist_ok=True)
        with open(os.path.join(self.state, "config.json"), "w") as f:
            json.dump(
                {
                    "source": "onthemarket",
                    "outcodes": ["SE15"],
                    "max_price": 550000,
                    "min_bedrooms": 2,
                },
                f,
            )
        db = pw.connect(os.path.join(self.state, "data", "property-watch.db"))
        db.execute(
            "INSERT INTO listings(id,source,outcode,first_seen,last_seen,price)"
            " VALUES ('otm:1','onthemarket','SE15','2026-11-01','2026-11-17',500000)"
        )
        db.commit()
        db.close()
        self.addCleanup(self.tmp.cleanup)

    def _run(self, payload):
        inbox = os.path.join(self.state, "data", "verdicts-inbox")
        os.makedirs(inbox, exist_ok=True)
        f = os.path.join(inbox, "v.json")
        with open(f, "w") as fh:
            fh.write(payload if isinstance(payload, str) else json.dumps(payload))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = pw.main(["--state", self.state, "--apply-verdicts", f])
        return rc, out.getvalue(), err.getvalue(), f

    def test_applying_verdicts_prints_nothing_on_stdout(self):
        rc, out, _err, _ = self._run([{"id": "otm:1", "verdict": "fine"}])
        self.assertEqual(rc, 0)
        self.assertEqual(out, "", "stdout must stay empty or the monitor hash moves")

    def test_rejections_go_to_stderr_and_name_the_row(self):
        """Silently dropping bad rows would hide a model that has quietly
        stopped producing usable judgement."""
        _rc, out, err, _ = self._run([{"id": "otm:ghost", "verdict": "invented"}])
        self.assertEqual(out, "")
        self.assertIn("otm:ghost", err)
        self.assertIn("unknown listing", err)

    def test_malformed_json_is_an_error_not_a_crash_and_stdout_stays_clean(self):
        rc, out, err, _ = self._run("{not json at all")
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, "")
        self.assertTrue(err.strip())

    def test_the_inbox_file_is_consumed(self):
        """Steady state is an empty inbox: a leftover file would be re-applied
        on the next run and silently re-date a verdict."""
        _rc, _out, _err, f = self._run([{"id": "otm:1", "verdict": "fine"}])
        self.assertFalse(os.path.exists(f))


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1)
