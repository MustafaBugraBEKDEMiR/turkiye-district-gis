# Report summary: MIS533 final project

**Course:** MIS533 Database Management Systems, M.Sc. in Management Information Systems,
Graduate School of Social Sciences, Ankara Yıldırım Beyazıt University
**Lecturer:** Assoc. Prof. Dr. Vildan Ateş
**Student:** Mustafa Buğra Bekdemir (245217115)
**Original submission:** 21 May 2025, *"A GIS-Based City and District Information Management System"*

This page summarises the original report and records how this repository extends it. The original
PDF report and slides are not included here.

## 1. Original project (May 2025)

**Motivation.** Local governments still work with paper records and disconnected databases. A
GIS-based city information system puts infrastructure and demographic data on a map, which supports
better decisions, lower cost, transparency, coordination between departments, and growth planning.

**Business requirements.**
1. Store geographic data for cities and districts.
2. Store demographic and infrastructure information for districts.
3. Model the city → district hierarchy.
4. Report via queries such as "the district with the most parks" and "the most populated district".
5. Update and query the data.

The report lists interviews, observation, surveys and document analysis as the methods for gathering
these requirements.

**Model.** Two entities in a 1:N relationship:

| Table | Attributes |
|---|---|
| `City` | `city_id`, `city_name` (unique), `population` (0–50,000,000) |
| `District` | `district_id`, `district_name`, `area` (> 0), `parks_count` (≥ 0), `schools_count` (≥ 0), `latitude` (−90…90), `longitude` (−180…180), `city_id` (FK), and later a `geom` point |

**Normalization.** The report shows 1NF (atomic values), 2NF (single-column keys, so no partial
dependency) and 3NF (no non-key attribute determines another).

**Implementation.** PostgreSQL with 5 cities × 2 districts of sample data and 15 SQL queries: joins,
aggregates, `NOT EXISTS`, top-N. A PostGIS point column was added with
`ST_SetSRID(ST_MakePoint(lon, lat), 4326)`.

## 2. Issues found when revisiting it

| # | Issue | Fix in this repository |
|---|---|---|
| 1 | Section "SQL Commands for Creating Tables" contained no `CREATE TABLE` statements | Full, re-runnable DDL in `sql/01_schema.sql` |
| 2 | Query 9 had a duplicated `GROUP BY` (syntax error) | Rewritten; CI runs every query on each push |
| 3 | "Most populated district" was required but districts had no population | `district_population(district_id, year, …)` |
| 4 | "Total population per city" did not aggregate | Province population = `SUM` over districts |
| 5 | Report says 5 cities, but the INSERT examples use ids 6–7 and data for the other cities is missing | Real data for all 81 provinces / 973 districts |
| 6 | `area` had no unit; `area > 30` filtered nothing | `area_km2`, computed geodesically from geometry |
| 7 | "GIS-based", but no spatial query (lat/lon `BETWEEN`) | PostGIS containment, adjacency, distance, KNN |

## 3. Normalization, revisited

The original 3NF argument holds for the attributes it lists. Adding geometry, however, creates
**derived attributes** that the original design stored as independent facts:

* `latitude`, `longitude` and `geom` encode the same fact (`geom → latitude, longitude`).
* `area` is a function of the boundary (`geom → area`).
* `parks_count` and `schools_count` are functions of where the facilities are
  (`{facility locations, district geom} → counts`).

Storing them separately risks update anomalies: a corrected boundary leaves a stale area, and a new
park leaves a stale count. The new design therefore:

1. Keeps **geometry as the single source of truth** and stores no lat/lon columns.
2. Maintains `area_km2` with a **trigger** (deliberate, controlled redundancy for query speed).
3. Stores facilities as their own entity and computes counts in a **materialized view**.
4. Derives province boundaries from districts (`ST_Union`) instead of storing them twice.
5. Moves population into a **(district_id, year)** table, because population is time-dependent;
   as a district column it would force overwriting history.

## 4. Extension summary

* **Data:** geoBoundaries ADM1/ADM2 (OSM) + TÜİK ADNKS 2021. Integrated with a spatial join and a
  3-pass, auditable name-matching procedure (915 exact / 8 alias / 50 "Merkez").
* **Analysis:** district indicators, province and region summaries, and a service-gap score with
  spatial-lag clustering (`sql/queries/03_decision_support.sql`).
* **Engineering:** Docker Compose, GitHub Actions, 30+ tests against published TÜİK totals, and a
  GiST index benchmark (≈17× speed-up).
* **Communication:** Leaflet web map on GitHub Pages and a choropleth figure.

## 5. Conclusion

The original project designed a small, correctly normalized relational schema. The extension turns
it into a reproducible spatial decision-support database. It integrates heterogeneous public data,
uses geometry as the authoritative representation of space, and answers a planning question that
goes beyond storage: where public services are least adequate relative to population.

## References

1. Republic of Türkiye Ministry of Environment, Urbanization and Climate Change, General Directorate of GIS. https://cbs.gov.tr/
2. PostgreSQL Global Development Group. https://www.postgresql.org/
3. PostGIS Project Steering Committee. https://postgis.net/
4. Runfola, D. et al. (2020). geoBoundaries: A global database of political administrative boundaries. *PLoS ONE* 15(4): e0231866.
5. TÜİK, Adrese Dayalı Nüfus Kayıt Sistemi Sonuçları, 2021.
6. OpenStreetMap contributors. https://www.openstreetmap.org/copyright
