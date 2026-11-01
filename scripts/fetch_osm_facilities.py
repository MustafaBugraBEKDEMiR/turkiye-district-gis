#!/usr/bin/env python3
"""
Download schools and parks for all 81 provinces from OpenStreetMap (Overpass API)
and write them to data/raw/osm_facilities.geojson for scripts/load_data.py.

  python scripts/fetch_osm_facilities.py            # all provinces (~15-30 min)
  python scripts/fetch_osm_facilities.py 6 34 35    # only Ankara, İstanbul, İzmir

* One request per province (ISO3166-2 area "TR-xx") keeps each query small.
* Responses are cached in data/raw/osm/TR-xx.json, so an interrupted run resumes.
* Schools -> one point each (OSM "center").  Parks -> their outline as lines;
  PostGIS assembles them into polygons with ST_BuildArea (sql/04_facilities.sql),
  which correctly handles multipolygon relations with holes and split rings.

Data © OpenStreetMap contributors, ODbL 1.0.
"""
from __future__ import annotations

import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Windows consoles may default to a legacy code page; we print Turkish text and ✓
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
CACHE = ROOT / "data" / "raw" / "osm"
OUT = ROOT / "data" / "raw" / "osm_facilities.geojson"

ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]

QUERY = """
[out:json][timeout:600];
area["ISO3166-2"="TR-{plate:02d}"]["admin_level"="4"]->.p;
(
  nwr["amenity"="school"](area.p);
)->.schools;
(
  nwr["leisure"="park"](area.p);
)->.parks;
.schools out center tags;
.parks out geom tags;
"""


def overpass(plate: int) -> dict:
    """Return the Overpass JSON for one province, using the on-disk cache."""
    cache = CACHE / f"TR-{plate:02d}.json"
    if cache.exists():
        return json.loads(cache.read_text(encoding="utf-8"))

    body = urllib.parse.urlencode({"data": QUERY.format(plate=plate)}).encode()
    delay = 10
    for attempt in range(6):
        url = ENDPOINTS[attempt % len(ENDPOINTS)]
        try:
            req = urllib.request.Request(
                url, data=body, headers={"User-Agent": "turkiye-district-gis/1.0"})
            with urllib.request.urlopen(req, timeout=900) as r:
                data = json.loads(r.read().decode("utf-8"))
            if "remark" in data and "error" in data["remark"].lower():
                raise RuntimeError(data["remark"])
            if not data.get("elements"):
                # every province has schools; an empty answer means the area
                # lookup or the server failed — never cache it
                raise RuntimeError("empty result")
            CACHE.mkdir(parents=True, exist_ok=True)
            cache.write_text(json.dumps(data), encoding="utf-8")
            return data
        except (urllib.error.URLError, TimeoutError, RuntimeError, ValueError) as e:
            print(f"    attempt {attempt + 1} failed ({e}); retrying in {delay}s")
            time.sleep(delay)
            delay *= 2
    raise SystemExit(f"Overpass failed for TR-{plate:02d}")


def _line(coords: list[dict]) -> list[list[float]]:
    return [[round(c["lon"], 7), round(c["lat"], 7)] for c in coords]


def element_to_feature(el: dict) -> dict | None:
    """Convert one Overpass element to a GeoJSON feature (or None to skip)."""
    tags = el.get("tags", {})
    if tags.get("amenity") == "school":
        kind = "school"
    elif tags.get("leisure") == "park":
        kind = "park"
    else:
        return None

    etype, eid = el["type"], el["id"]
    geom = None

    if etype == "node":
        geom = {"type": "Point", "coordinates": [el["lon"], el["lat"]]}
    elif kind == "school" and "center" in el:
        geom = {"type": "Point",
                "coordinates": [el["center"]["lon"], el["center"]["lat"]]}
    elif kind == "park" and etype == "way" and el.get("geometry"):
        geom = {"type": "MultiLineString", "coordinates": [_line(el["geometry"])]}
    elif kind == "park" and etype == "relation":
        lines = [_line(m["geometry"]) for m in el.get("members", [])
                 if m.get("type") == "way" and m.get("geometry")
                 and m.get("role") in ("outer", "inner", "")]
        if lines:
            geom = {"type": "MultiLineString", "coordinates": lines}

    if geom is None:
        return None
    return {
        "type": "Feature",
        "properties": {"osm_ref": f"{etype}/{eid}", "type": kind,
                       "name": tags.get("name")},
        "geometry": geom,
    }


def main(argv: list[str]) -> None:
    plates = [int(a) for a in argv] or list(range(1, 82))
    features: dict[str, dict] = {}
    for plate in plates:
        t = time.perf_counter()
        data = overpass(plate)
        n = 0
        for el in data.get("elements", []):
            f = element_to_feature(el)
            if f:
                features[f["properties"]["osm_ref"]] = f   # de-duplicate across provinces
                n += 1
        print(f"  TR-{plate:02d}: {n:6d} features  ({time.perf_counter() - t:4.1f}s)")
        time.sleep(1)   # be polite to the public Overpass servers

    OUT.write_text(json.dumps({
        "type": "FeatureCollection",
        "attribution": "© OpenStreetMap contributors, ODbL 1.0",
        "features": list(features.values()),
    }, ensure_ascii=False), encoding="utf-8")
    kinds = [f["properties"]["type"] for f in features.values()]
    print(f"\nWrote {OUT.relative_to(ROOT)}: {kinds.count('school')} schools, "
          f"{kinds.count('park')} parks.\nNow re-run: python scripts/load_data.py")


if __name__ == "__main__":
    main(sys.argv[1:])
