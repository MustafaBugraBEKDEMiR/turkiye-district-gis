#!/usr/bin/env python3
"""
Export the reporting layer for the static web map (docs/, served by GitHub Pages).

  python scripts/export_web.py

Writes
  docs/data/districts.geojson  district polygons (simplified) + indicators
  docs/data/provinces.geojson  province outlines (simplified)
  docs/data/meta.json          sources, population year, facility-layer status
"""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

import psycopg

from load_data import dsn

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "data"

DISTRICTS_SQL = """
SELECT json_build_object('type', 'FeatureCollection', 'features',
         json_agg(ST_AsGeoJSON(t.*, 'geom', 4)::json ORDER BY t.district_id))
FROM (
    SELECT district_id, tuik_code, district, province, region, year,
           population, area_km2, density_per_km2, share_of_province_pct,
           pop_rank_in_province, schools, parks, people_per_school,
           park_m2_per_capita, service_gap_score,
           ST_SimplifyPreserveTopology(geom, 0.003) AS geom
    FROM report.district_indicators
) t
"""

PROVINCES_SQL = """
SELECT json_build_object('type', 'FeatureCollection', 'features',
         json_agg(ST_AsGeoJSON(t.*, 'geom', 4)::json ORDER BY t.province_id))
FROM (
    SELECT province_id, province, population, density_per_km2,
           ST_SimplifyPreserveTopology(geom, 0.005) AS geom
    FROM report.province_summary
) t
"""


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    with psycopg.connect(dsn()) as conn:
        districts = conn.execute(DISTRICTS_SQL).fetchone()[0]
        provinces = conn.execute(PROVINCES_SQL).fetchone()[0]
        year, n_fac = conn.execute(
            "SELECT max(year), (SELECT count(*) FROM gis.facility) "
            "FROM gis.district_population").fetchone()

    for name, doc in [("districts", districts), ("provinces", provinces)]:
        path = OUT / f"{name}.geojson"
        path.write_text(json.dumps(doc, ensure_ascii=False, separators=(",", ":")),
                        encoding="utf-8")
        print(f"  ✓ {path.relative_to(ROOT)}  {path.stat().st_size / 1e6:.2f} MB")

    meta = {
        "generated": date.today().isoformat(),
        "population_year": year,
        "facilities_loaded": n_fac > 0,
        "facility_count": n_fac,
        "sources": [
            "Boundaries: geoBoundaries gbOpen TUR ADM1/ADM2 (OpenStreetMap, ODbL 1.0)",
            f"Population: TÜİK ADNKS {year}",
            "Schools & parks: © OpenStreetMap contributors (ODbL 1.0)",
        ],
    }
    (OUT / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2),
                                   encoding="utf-8")
    print(f"  ✓ docs/data/meta.json  (facilities loaded: {meta['facilities_loaded']})")


if __name__ == "__main__":
    main()
