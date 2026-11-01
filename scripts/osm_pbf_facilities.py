#!/usr/bin/env python3
"""
Extract schools and parks for the whole of Türkiye from a Geofabrik OSM extract
(recommended for the full country; scripts/fetch_osm_facilities.py uses the
Overpass API and is better for a few provinces).

  python scripts/osm_pbf_facilities.py                    # downloads turkey-latest.osm.pbf (~0.6 GB)
  python scripts/osm_pbf_facilities.py path/to/file.osm.pbf

Needs osmium-tool (`apt install osmium-tool`, `brew install osmium-tool`,
or `conda install -c conda-forge osmium-tool`). osmium assembles multipolygon
relations itself, so parks arrive as finished (Multi)Polygons.

Writes data/raw/osm_facilities.geojson (same format as fetch_osm_facilities.py).
Data © OpenStreetMap contributors, ODbL 1.0.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
OUT = RAW / "osm_facilities.geojson"
PBF_URL = "https://download.geofabrik.de/europe/turkey-latest.osm.pbf"

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)


def run(*cmd: str) -> None:
    print("  $", " ".join(cmd))
    subprocess.run(cmd, check=True)


def classify(tags: dict) -> str | None:
    if tags.get("amenity") == "school":
        return "school"
    if tags.get("leisure") == "park":
        return "park"
    return None


def record_to_feature(rec: dict) -> dict | None:
    """One osmium-export GeoJSON record -> our facility feature (or None)."""
    props = rec.get("properties", {})
    kind = classify(props)
    geom = rec.get("geometry") or {}
    if kind is None or geom.get("type") not in ("Point", "Polygon", "MultiPolygon"):
        return None                       # e.g. an unclosed park outline (LineString)
    osm_type = {"n": "node", "w": "way", "r": "relation",
                "node": "node", "way": "way", "relation": "relation"}[str(props["@type"])]
    return {
        "type": "Feature",
        "properties": {"osm_ref": f"{osm_type}/{props['@id']}", "type": kind,
                       "name": props.get("name")},
        "geometry": geom,
    }


def main(argv: list[str]) -> None:
    if not shutil.which("osmium"):
        sys.exit("osmium-tool is not installed (see the docstring).")
    if argv:
        pbf = Path(argv[0])
    else:
        pbf = RAW / "osm" / "turkey-latest.osm.pbf"
        if not pbf.exists():
            pbf.parent.mkdir(parents=True, exist_ok=True)
            print(f"downloading {PBF_URL}")
            urllib.request.urlretrieve(PBF_URL, pbf)
    print(f"source: {pbf} ({pbf.stat().st_size / 1e6:.0f} MB)")

    with tempfile.TemporaryDirectory() as tmp:
        filtered = Path(tmp) / "facilities.osm.pbf"
        seq = Path(tmp) / "facilities.geojsonseq"
        run("osmium", "tags-filter", "--overwrite", "-o", str(filtered), str(pbf),
            "nwr/amenity=school", "nwr/leisure=park")
        run("osmium", "export", "--overwrite", "-f", "geojsonseq",
            "-x", "print_record_separator=false",
            "--geometry-types=point,polygon", "-a", "type,id",
            "-o", str(seq), str(filtered))

        features: dict[str, dict] = {}
        with seq.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip().lstrip("\x1e")
                if line and (f := record_to_feature(json.loads(line))):
                    features[f["properties"]["osm_ref"]] = f

    OUT.write_text(json.dumps({
        "type": "FeatureCollection",
        "attribution": "© OpenStreetMap contributors, ODbL 1.0 (Geofabrik extract)",
        "features": list(features.values()),
    }, ensure_ascii=False), encoding="utf-8")
    kinds = [f["properties"]["type"] for f in features.values()]
    print(f"wrote {OUT.relative_to(ROOT)}: {kinds.count('school'):,} schools, "
          f"{kinds.count('park'):,} parks")


if __name__ == "__main__":
    main(sys.argv[1:])
