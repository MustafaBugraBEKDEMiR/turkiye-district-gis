-- =====================================================================
-- 04_performance.sql — what does the GiST index buy us?
--
-- Workload: assign 10,000 random points inside Türkiye's bounding box to
-- their district (point-in-polygon), with and without the spatial index.
-- Run with:  psql -f sql/queries/04_performance.sql
-- =====================================================================
SET search_path = gis, public;

DROP TABLE IF EXISTS random_points;
CREATE TEMP TABLE random_points AS
SELECT i AS id,
       ST_SetSRID(ST_MakePoint(26 + random() * 19, 36 + random() * 6), 4326) AS geom
FROM   generate_series(1, 10000) i;
ANALYZE random_points;

\echo '--- with GiST index -------------------------------------------'
EXPLAIN (ANALYZE, COSTS OFF, TIMING ON, SUMMARY ON)
SELECT p.id, d.district_id
FROM   random_points p JOIN district d ON ST_Intersects(d.geom, p.geom);

\echo '--- without index (sequential scan, forced) ---------------------'
BEGIN;
SET LOCAL enable_indexscan  = off;
SET LOCAL enable_bitmapscan = off;
EXPLAIN (ANALYZE, COSTS OFF, TIMING ON, SUMMARY ON)
SELECT p.id, d.district_id
FROM   random_points p JOIN district d ON ST_Intersects(d.geom, p.geom);
COMMIT;
