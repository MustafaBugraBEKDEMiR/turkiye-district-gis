-- =====================================================================
-- 05_views.sql — reporting layer (schema "report")
--
--   report.facility_district   which district each facility belongs to
--   report.district_indicators per-district indicators (materialized)
--   report.province_summary    province totals + dissolved boundary (materialized)
--   report.region_summary      region totals
--   report.refresh()           rebuild materialized views after data changes
-- =====================================================================

SET search_path = report, gis, public;

-- ---------------------------------------------------------------------
-- Facility -> district (spatial join on a representative point so a park
-- that straddles a border is counted exactly once)
-- ---------------------------------------------------------------------
CREATE VIEW report.facility_district AS
SELECT f.facility_id, f.type_code, f.name, f.area_m2, d.district_id
FROM   gis.facility f
JOIN   gis.district d ON ST_Intersects(d.geom, ST_PointOnSurface(f.geom));

-- ---------------------------------------------------------------------
-- District indicators (latest population year)
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW report.district_indicators AS
WITH latest AS (
    SELECT max(year) AS year FROM gis.district_population
),
pop AS (
    SELECT dp.district_id, dp.year, dp.total, dp.male, dp.female
    FROM   gis.district_population dp JOIN latest USING (year)
),
fac AS (
    SELECT district_id,
           count(*) FILTER (WHERE type_code = 'school')                 AS schools,
           count(*) FILTER (WHERE type_code = 'park')                   AS parks,
           coalesce(sum(area_m2) FILTER (WHERE type_code = 'park'), 0)  AS park_area_m2
    FROM   report.facility_district
    GROUP  BY district_id
),
has_fac AS (                       -- is the optional facility layer loaded at all?
    SELECT EXISTS (SELECT 1 FROM gis.facility) AS loaded
),
base AS (
    SELECT d.district_id, d.tuik_code, d.name AS district, p.province_id,
           p.name AS province, r.name_en AS region,
           d.area_km2, pop.year, pop.total AS population, pop.male, pop.female,
           round(pop.total / d.area_km2, 1)                              AS density_per_km2,
           round(100.0 * pop.total / sum(pop.total) OVER (PARTITION BY p.province_id), 2)
                                                                          AS share_of_province_pct,
           CASE WHEN h.loaded THEN coalesce(fac.schools, 0) END           AS schools,
           CASE WHEN h.loaded THEN coalesce(fac.parks, 0) END             AS parks,
           CASE WHEN h.loaded THEN coalesce(fac.park_area_m2, 0) END      AS park_area_m2,
           d.geom
    FROM   gis.district d
    JOIN   gis.province p USING (province_id)
    JOIN   gis.region   r USING (region_id)
    JOIN   pop              USING (district_id)
    LEFT   JOIN fac         USING (district_id)
    CROSS  JOIN has_fac h
),
ind AS (
    SELECT b.*,
           round(population::numeric / nullif(schools, 0), 0)            AS people_per_school,
           round(park_area_m2 / nullif(population, 0), 2)                AS park_m2_per_capita
    FROM   base b
)
SELECT ind.*,
       rank() OVER (PARTITION BY province_id ORDER BY population DESC)      AS pop_rank_in_province,
       rank() OVER (PARTITION BY province_id ORDER BY density_per_km2 DESC) AS density_rank_in_province,
       -- Service-gap score in [0,1]: mean of national percentile ranks of
       -- people per school (more = worse) and park m² per capita (less = worse).
       -- Districts without any school get the worst school percentile.
       CASE WHEN schools IS NOT NULL THEN round((
            percent_rank() OVER (ORDER BY coalesce(people_per_school, 1e9))
          + percent_rank() OVER (ORDER BY park_m2_per_capita DESC NULLS FIRST)
       )::numeric / 2, 3) END                                                AS service_gap_score
FROM ind;

CREATE UNIQUE INDEX district_indicators_pk  ON report.district_indicators (district_id);
CREATE INDEX        district_indicators_gix ON report.district_indicators USING gist (geom);

-- ---------------------------------------------------------------------
-- Province summary: boundary DERIVED from districts (no duplicate storage)
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW report.province_summary AS
SELECT province_id, province, region,
       count(*)                                   AS districts,
       sum(population)                            AS population,
       sum(area_km2)                              AS area_km2,
       round(sum(population) / sum(area_km2), 1)  AS density_per_km2,
       sum(schools)                               AS schools,
       sum(parks)                                 AS parks,
       round(sum(park_area_m2) / sum(population), 2) AS park_m2_per_capita,
       ST_Multi(ST_Union(geom))::geometry(MultiPolygon, 4326) AS geom
FROM   report.district_indicators
GROUP  BY province_id, province, region;

CREATE UNIQUE INDEX province_summary_pk  ON report.province_summary (province_id);
CREATE INDEX        province_summary_gix ON report.province_summary USING gist (geom);

CREATE VIEW report.region_summary AS
SELECT region,
       count(*)                                    AS provinces,
       sum(districts)                              AS districts,
       sum(population)                             AS population,
       round(sum(area_km2))                        AS area_km2,
       round(sum(population) / sum(area_km2), 1)   AS density_per_km2,
       round(100.0 * sum(population) / sum(sum(population)) OVER (), 2) AS share_pct
FROM   report.province_summary
GROUP  BY region;

-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION report.refresh()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY report.district_indicators;
    REFRESH MATERIALIZED VIEW CONCURRENTLY report.province_summary;
END $$;

-- ---------------------------------------------------------------------
-- Read-only role for analysts / a future API
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gis_reader') THEN
        CREATE ROLE gis_reader NOLOGIN;
    END IF;
END $$;
GRANT USAGE  ON SCHEMA gis, report TO gis_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA gis, report TO gis_reader;
