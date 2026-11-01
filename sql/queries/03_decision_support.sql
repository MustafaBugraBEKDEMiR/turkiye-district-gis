-- =====================================================================
-- 03_decision_support.sql — "Which districts are under-served?"
--
-- Queries 1–2 use population and geometry only. Queries 3–7 need the
-- optional OpenStreetMap facility layer (scripts/fetch_osm_facilities.py);
-- without it the facility columns are NULL.
--
-- Caveat: OSM completeness varies between cities. Low counts can mean
-- "not mapped yet" as well as "not there", so treat the results as a
-- screening tool that points to where to look, not as an official audit.
-- =====================================================================
SET search_path = report, gis, public;

-- Green-space benchmark in m² per person. Turkish planning regulations and
-- the literature cite values between 9 and 15 m² — change it here.
\set green_std 10

-- 1. Primacy: how much of each province lives in its largest district?
--    High values = services concentrated in one centre.
SELECT DISTINCT ON (province) province, district AS largest_district,
       share_of_province_pct
FROM   district_indicators
ORDER  BY province, share_of_province_pct DESC;

-- (sorted view of the same idea: the 10 most mono-centric provinces)
SELECT province, max(share_of_province_pct) AS largest_district_share_pct
FROM   district_indicators
GROUP  BY province
ORDER  BY 2 DESC
LIMIT  10;

-- 2. Sparsely populated districts (< 20 people/km²) — long travel
--    distances make mobile / shared services more relevant here
SELECT province, district, population, area_km2, density_per_km2
FROM   district_indicators
WHERE  density_per_km2 < 20
ORDER  BY density_per_km2
LIMIT  20;

-- 3. The 20 most under-served districts (service-gap score, 0..1)
SELECT district, province, population, schools, people_per_school,
       parks, park_m2_per_capita, service_gap_score
FROM   district_indicators
WHERE  service_gap_score IS NOT NULL
ORDER  BY service_gap_score DESC
LIMIT  20;

-- 4. Populous districts (> 50,000 people) with no mapped park at all
SELECT district, province, population
FROM   district_indicators
WHERE  parks = 0 AND population > 50000
ORDER  BY population DESC;

-- 5. Province-level green-space deficit against the benchmark
SELECT province, population, park_m2_per_capita,
       round(greatest(:green_std - park_m2_per_capita, 0) * population / 1e4, 1)
           AS deficit_hectares
FROM   province_summary
WHERE  park_m2_per_capita IS NOT NULL
ORDER  BY deficit_hectares DESC
LIMIT  15;

-- 6. "Where should the next school go?" — in each province, the district
--    with the most people per school
SELECT DISTINCT ON (province) province, district, population, schools, people_per_school
FROM   district_indicators
WHERE  schools IS NOT NULL
ORDER  BY province, people_per_school DESC NULLS FIRST;

-- 7. Spatial clusters of need: under-served districts whose neighbours
--    are under-served too (mean score of adjacent districts = spatial lag)
WITH lag AS (
    SELECT a.district_id,
           round(avg(b.service_gap_score), 3) AS neighbour_score
    FROM   district_indicators a
    JOIN   district_indicators b
           ON b.district_id <> a.district_id AND ST_Intersects(a.geom, b.geom)
    GROUP  BY a.district_id
)
SELECT d.district, d.province, d.service_gap_score, l.neighbour_score
FROM   district_indicators d JOIN lag l USING (district_id)
WHERE  d.service_gap_score >= 0.75 AND l.neighbour_score >= 0.75
ORDER  BY d.service_gap_score + l.neighbour_score DESC
LIMIT  20;
