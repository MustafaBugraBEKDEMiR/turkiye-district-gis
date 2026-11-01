-- =====================================================================
-- 04_facilities.sql — schools & parks from OpenStreetMap (optional layer)
--
-- Input: staging.raw_document where source = 'osm_facilities', a GeoJSON
-- FeatureCollection produced by scripts/fetch_osm_facilities.py with
-- properties {osm_ref, type, name}. If the file was not fetched, this
-- script does nothing and the facility-based indicators stay NULL.
-- =====================================================================

SET search_path = gis, public;

INSERT INTO facility (type_code, osm_ref, name, geom)
SELECT DISTINCT ON (f -> 'properties' ->> 'osm_ref')
       f -> 'properties' ->> 'type',
       f -> 'properties' ->> 'osm_ref',
       left(nullif(btrim(f -> 'properties' ->> 'name'), ''), 200),
       g.geom
FROM   staging.raw_document r,
       jsonb_array_elements(r.doc -> 'features') f,
       LATERAL (
           SELECT CASE
                    WHEN GeometryType(raw) = 'POINT' THEN raw
                    -- park outlines arrive as lines: merge the pieces of
                    -- split rings, then let PostGIS build the polygon(s),
                    -- holes included (inner rings of multipolygon relations)
                    WHEN GeometryType(raw) IN ('LINESTRING', 'MULTILINESTRING') THEN
                         ST_Multi(ST_CollectionExtract(
                             ST_MakeValid(ST_BuildArea(ST_LineMerge(raw))), 3))
                    ELSE ST_Multi(ST_CollectionExtract(ST_MakeValid(raw), 3))
                  END AS geom
           FROM (SELECT ST_SetSRID(ST_GeomFromGeoJSON(f -> 'geometry'), 4326) AS raw) s
       ) g
WHERE  r.source = 'osm_facilities'
  AND  f -> 'properties' ->> 'type' IN (SELECT type_code FROM facility_type)
  AND  g.geom IS NOT NULL
  AND  NOT ST_IsEmpty(g.geom)          -- unclosed park outlines are dropped
ORDER  BY f -> 'properties' ->> 'osm_ref';

-- Keep only facilities inside Türkiye's districts (the OSM area query
-- can return features that touch the border from outside).
DELETE FROM facility f
WHERE NOT EXISTS (
    SELECT 1 FROM district d
    WHERE ST_Intersects(d.geom, ST_PointOnSurface(f.geom)));

DO $$
BEGIN
    RAISE NOTICE 'facilities loaded: % schools, % parks',
        (SELECT count(*) FROM gis.facility WHERE type_code = 'school'),
        (SELECT count(*) FROM gis.facility WHERE type_code = 'park');
END $$;

ANALYZE facility;
