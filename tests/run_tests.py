#!/usr/bin/env python3
"""
Test suite. Expects a database already built by scripts/load_data.py.

  python tests/run_tests.py

1. unit tests for the OSM -> GeoJSON converter
2. tests/sql/test_core.sql        (counts, official population totals,
                                   geometry, functions, constraints, triggers)
3. facility pipeline on a hand-written fixture: the fixture goes through the
   real sql/04_facilities.sql, is checked by tests/sql/test_facilities.sql,
   and the previous facility data is restored afterwards.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from fetch_osm_facilities import element_to_feature  # noqa: E402
from load_data import dsn  # noqa: E402

FIXTURE = ROOT / "tests" / "fixtures" / "overpass_sample.json"


class ConverterTest(unittest.TestCase):
    def setUp(self):
        els = json.loads(FIXTURE.read_text(encoding="utf-8"))["elements"]
        self.by_id = {f"{e['type']}/{e['id']}": e for e in els}

    def conv(self, ref):
        return element_to_feature(self.by_id[ref])

    def test_school_node_is_point(self):
        f = self.conv("node/1")
        self.assertEqual(f["geometry"]["type"], "Point")
        self.assertEqual(f["properties"]["type"], "school")

    def test_school_way_uses_center(self):
        self.assertEqual(self.conv("way/2")["geometry"]["coordinates"], [32.855, 39.912])

    def test_park_way_is_linework(self):
        self.assertEqual(self.conv("way/10")["geometry"]["type"], "MultiLineString")

    def test_park_relation_keeps_all_members(self):
        self.assertEqual(len(self.conv("relation/12")["geometry"]["coordinates"]), 3)

    def test_irrelevant_tags_skipped(self):
        self.assertIsNone(self.conv("node/14"))


def run_sql_file(conn: psycopg.Connection, path: Path) -> None:
    # strip psql meta-commands (\set ...) so the file also runs through psycopg
    sql = "\n".join(l for l in path.read_text(encoding="utf-8").splitlines()
                    if not l.lstrip().startswith("\\"))
    conn.execute(sql)


def facility_pipeline(conn: psycopg.Connection) -> None:
    saved = conn.execute(
        "SELECT source, url, doc FROM staging.raw_document "
        "WHERE source LIKE 'osm_facilities%'").fetchall()

    def load(rows):
        conn.execute("DELETE FROM staging.raw_document WHERE source LIKE 'osm_facilities%'")
        conn.execute("TRUNCATE gis.facility RESTART IDENTITY")
        for source, url, doc in rows:
            conn.execute("INSERT INTO staging.raw_document (source, url, doc) VALUES "
                         "(%s, %s, %s)", (source, url, Jsonb(doc)))
        run_sql_file(conn, ROOT / "sql" / "04_facilities.sql")
        conn.execute("SELECT report.refresh()")

    els = json.loads(FIXTURE.read_text(encoding="utf-8"))["elements"]
    fixture = {"type": "FeatureCollection",
               "features": [f for f in map(element_to_feature, els) if f]}
    try:
        load([("osm_facilities#0001", "test-fixture", fixture)])
        run_sql_file(conn, ROOT / "tests" / "sql" / "test_facilities.sql")
    finally:
        load(saved)   # restore the real layer (or nothing)


def main() -> int:
    print("== 1. converter unit tests")
    result = unittest.TextTestRunner(verbosity=1).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ConverterTest))
    if not result.wasSuccessful():
        return 1

    failures = 0
    with psycopg.connect(dsn(), autocommit=True) as conn:
        conn.add_notice_handler(lambda d: print("   ", d.message_primary))
        for title, fn in [
            ("2. core database tests", lambda: run_sql_file(conn, ROOT / "tests" / "sql" / "test_core.sql")),
            ("3. facility pipeline tests", lambda: facility_pipeline(conn)),
        ]:
            print(f"== {title}")
            try:
                fn()
            except psycopg.Error as e:
                print(f"    {e.diag.message_primary or e}")
                failures += 1
    print("\nALL TESTS PASSED" if failures == 0 else f"\n{failures} TEST GROUP(S) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
