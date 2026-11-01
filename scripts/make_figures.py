#!/usr/bin/env python3
"""
Render the README figure(s) straight from the database.

  pip install matplotlib shapely
  python scripts/make_figures.py
"""
from __future__ import annotations

from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import psycopg
from matplotlib.collections import PatchCollection
from matplotlib.colors import BoundaryNorm, ListedColormap
from matplotlib.patches import Polygon as MplPolygon
from shapely import wkb

from load_data import dsn

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "img"

BLUES = ["#eef5f9", "#cfe3ee", "#a6cbe0", "#73aecd", "#4790b8", "#22709c", "#0b4f74"]


def patches(geom) -> list[MplPolygon]:
    polys = getattr(geom, "geoms", [geom])
    return [MplPolygon(np.asarray(p.exterior.coords), closed=True) for p in polys]


def density_map(conn: psycopg.Connection) -> None:
    rows = conn.execute("""
        SELECT density_per_km2,
               ST_AsBinary(ST_Transform(ST_SimplifyPreserveTopology(geom, 0.003), 3857))
        FROM report.district_indicators""").fetchall()
    provinces = conn.execute("""
        SELECT ST_AsBinary(ST_Transform(ST_SimplifyPreserveTopology(geom, 0.004), 3857))
        FROM report.province_summary""").fetchall()
    year = conn.execute("SELECT max(year) FROM gis.district_population").fetchone()[0]

    bounds = [0, 25, 50, 100, 250, 1000, 5000, 1e6]
    labels = ["< 25", "25–50", "50–100", "100–250", "250–1,000", "1,000–5,000", "> 5,000"]
    cmap, norm = ListedColormap(BLUES), BoundaryNorm(bounds, len(BLUES))

    fig, ax = plt.subplots(figsize=(14, 6.6), dpi=150)
    ps, vals = [], []
    for density, g in rows:
        for p in patches(wkb.loads(bytes(g))):
            ps.append(p)
            vals.append(float(density))
    coll = PatchCollection(ps, cmap=cmap, norm=norm, edgecolor="white", linewidth=0.15)
    coll.set_array(np.array(vals))
    ax.add_collection(coll)

    outline = []
    for (g,) in provinces:
        outline += patches(wkb.loads(bytes(g)))
    ax.add_collection(PatchCollection(outline, facecolor="none",
                                      edgecolor="#38475a", linewidth=0.45))
    ax.autoscale_view()
    ax.set_aspect("equal")
    ax.axis("off")

    handles = [plt.Rectangle((0, 0), 1, 1, color=c) for c in BLUES]
    ax.legend(handles, labels, title="People per km²", loc="lower left",
              frameon=False, fontsize=9, title_fontsize=9.5, ncol=1)
    ax.set_title(f"Population density of Türkiye's 973 districts (TÜİK ADNKS {year})",
                 loc="left", fontsize=13, color="#1d2733", pad=8)
    fig.text(0.99, 0.02,
             "Boundaries: geoBoundaries / © OpenStreetMap contributors (ODbL) · "
             "Population: TÜİK · computed with PostGIS",
             ha="right", fontsize=7.5, color="#5d6b7a")
    fig.tight_layout()
    OUT.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT / "density_map.png", bbox_inches="tight", facecolor="white")
    print(f"  ✓ {(OUT / 'density_map.png').relative_to(ROOT)}")


if __name__ == "__main__":
    with psycopg.connect(dsn()) as c:
        density_map(c)
