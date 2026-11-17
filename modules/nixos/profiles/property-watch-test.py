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

import importlib.util
import json
import os
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


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1)
