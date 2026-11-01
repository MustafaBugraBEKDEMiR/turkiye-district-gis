#!/usr/bin/env python3
"""
Build the database end-to-end.

  1. download the raw source files into data/raw/ (cached, skipped if present)
  2. run sql/00_init.sql .. 02_functions.sql  (schemas, tables, triggers)
  3. store each raw file as jsonb in staging.raw_document
  4. run sql/03_transform.sql .. 05_*.sql      (staging -> gis -> report)

All transformation logic lives in SQL; this script only moves files.

Usage:
    python scripts/load_data.py                # uses PG* env vars or defaults
    DATABASE_URL=postgresql://gis:gis@localhost:5432/citygis python scripts/load_data.py
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parent.parent

# Windows consoles may default to a legacy code page; we print Turkish text and ✓
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
RAW = ROOT / "data" / "raw"
SQL = ROOT / "sql"

GB = "https://media.githubusercontent.com/media/wmgeolab/geoBoundaries/main/releaseData/gbOpen/TUR"

# source key -> (url, local file name, required?)
SOURCES: dict[str, tuple[str, str, bool]] = {
    "geoboundaries_adm1": (f"{GB}/ADM1/geoBoundaries-TUR-ADM1_simplified.geojson",
                           "geoBoundaries-TUR-ADM1_simplified.geojson", True),
    "geoboundaries_adm2": (f"{GB}/ADM2/geoBoundaries-TUR-ADM2_simplified.geojson",
                           "geoBoundaries-TUR-ADM2_simplified.geojson", True),
    "tuik_adnks":         ("https://raw.githubusercontent.com/snrylmz/il-ilce-json/v1.0.1/js/il-ilce.json",
                           "tuik-adnks-il-ilce.json", True),
    # Produced by scripts/fetch_osm_facilities.py (optional layer)
    "osm_facilities":     ("local:scripts/fetch_osm_facilities.py",
                           "osm_facilities.geojson", False),
}

CHUNK = 20_000   # features per staging row for the facility layer

SQL_BEFORE_STAGING = ["00_init.sql", "01_schema.sql", "02_functions.sql"]
SQL_AFTER_STAGING = ["03_transform.sql", "04_facilities.sql", "05_views.sql"]


def dsn() -> str:
    if url := os.environ.get("DATABASE_URL"):
        return url
    return "host={} port={} dbname={} user={} password={}".format(
        os.environ.get("PGHOST", "localhost"),
        os.environ.get("PGPORT", "5432"),
        os.environ.get("PGDATABASE", "citygis"),
        os.environ.get("PGUSER", "gis"),
        os.environ.get("PGPASSWORD", "gis"),
    )


def download(url: str, target: Path) -> None:
    print(f"  downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "turkiye-district-gis/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    if data.startswith(b"version https://git-lfs"):
        sys.exit(f"Got a Git LFS pointer instead of data for {url}")
    target.write_bytes(data)


def fetch_sources() -> dict[str, Path]:
    RAW.mkdir(parents=True, exist_ok=True)
    files = {}
    print("[1/4] source files")
    for key, (url, name, required) in SOURCES.items():
        path = RAW / name
        if not path.exists():
            if url.startswith("local:"):
                print(f"  - {key}: not found ({name}); optional layer skipped")
                continue
            download(url, path)
        sha = hashlib.sha256(path.read_bytes()).hexdigest()[:12]
        print(f"  ✓ {key:20s} {path.stat().st_size/1e6:6.1f} MB  sha256:{sha}")
        files[key] = path
    missing = [k for k, (_, _, req) in SOURCES.items() if req and k not in files]
    if missing:
        sys.exit(f"missing required sources: {missing}")
    return files


def run_sql(conn: psycopg.Connection, name: str) -> None:
    t = time.perf_counter()
    conn.execute((SQL / name).read_text(encoding="utf-8"))
    conn.commit()
    print(f"  ✓ {name:22s} {time.perf_counter() - t:5.1f}s")


def main() -> None:
    files = fetch_sources()
    with psycopg.connect(dsn()) as conn:
        # NOTICEs raised by the SQL scripts (data-quality report) are shown
        conn.add_notice_handler(lambda d: print(f"    · {d.message_primary}"))

        print("[2/4] schema")
        for name in SQL_BEFORE_STAGING:
            run_sql(conn, name)

        print("[3/4] staging")
        for key, path in files.items():
            doc = json.loads(path.read_text(encoding="utf-8"))
            url = SOURCES[key][0]
            # a single jsonb value is limited to ~255 MB, so the (large, optional)
            # facility layer is stored in chunks: osm_facilities#0001, #0002, ...
            if key == "osm_facilities":
                feats = doc["features"]
                parts = [(f"{key}#{i // CHUNK + 1:04d}",
                          {"type": "FeatureCollection", "features": feats[i:i + CHUNK]})
                         for i in range(0, len(feats), CHUNK)] or [(f"{key}#0001", doc)]
            else:
                parts = [(key, doc)]
            for source, part in parts:
                conn.execute(
                    "INSERT INTO staging.raw_document (source, url, doc) VALUES (%s, %s, %s)",
                    (source, url, psycopg.types.json.Jsonb(part)),
                )
            print(f"  ✓ staging.raw_document ← {key}" + (f" ({len(parts)} chunks)" if len(parts) > 1 else ""))
        conn.commit()

        print("[4/4] transform & reporting layer")
        for name in SQL_AFTER_STAGING:
            run_sql(conn, name)

        row = conn.execute("""
            SELECT (SELECT count(*) FROM gis.province),
                   (SELECT count(*) FROM gis.district),
                   (SELECT sum(total) FROM gis.district_population
                     WHERE year = (SELECT max(year) FROM gis.district_population)),
                   (SELECT count(*) FROM gis.facility)
        """).fetchone()
        print(f"\nDone: {row[0]} provinces, {row[1]} districts, "
              f"latest population = {row[2]:,}, facilities = {row[3]:,}")


if __name__ == "__main__":
    main()
