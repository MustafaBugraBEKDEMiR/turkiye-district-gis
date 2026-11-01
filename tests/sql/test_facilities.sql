-- =====================================================================
-- test_facilities.sql — runs AFTER tests/fixtures/overpass_sample.json
-- has been loaded through the real pipeline (04_facilities.sql).
-- Fixture: 3 schools (one outside Türkiye), 4 parks (one unclosed,
-- one relation with a split outer ring and a hole, one node).
-- =====================================================================
\set ON_ERROR_STOP on
SET search_path = gis, report, public;

CREATE OR REPLACE FUNCTION pg_temp.check(label text, actual anyelement, expected anyelement)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL %: expected %, got %', label, expected, actual;
    END IF;
    RAISE NOTICE 'ok   %', label;
END $$;

SELECT pg_temp.check('school outside Türkiye removed',
    (SELECT count(*) FROM facility WHERE type_code = 'school'), 2::bigint);
SELECT pg_temp.check('unclosed park dropped, others kept',
    (SELECT count(*) FROM facility WHERE type_code = 'park'), 3::bigint);
SELECT pg_temp.check('relation assembled into ONE polygon with a hole',
    (SELECT ST_NumInteriorRings(ST_GeometryN(geom, 1)) FROM facility WHERE osm_ref = 'relation/12'), 1);
-- outer 0.010° x 0.008° (~854 m x 888 m) minus hole 0.004° x 0.004°
-- (~342 m x 444 m) at ~39.9°N  ->  ~606,600 m² (~60.7 ha)
SELECT pg_temp.check('area of park with hole ≈ 60.7 ha',
    (SELECT area_m2 BETWEEN 590000 AND 625000 FROM facility WHERE osm_ref = 'relation/12'), true);
SELECT pg_temp.check('point park has no area',
    (SELECT area_m2 FROM facility WHERE osm_ref = 'node/13'), NULL::numeric);
SELECT pg_temp.check('Çankaya gets 2 schools / 3 parks',
    (SELECT schools || '/' || parks FROM district_indicators WHERE district = 'Çankaya'), '2/3');
SELECT pg_temp.check('service gap score computed for all districts',
    (SELECT count(service_gap_score) FROM district_indicators), 973::bigint);
SELECT pg_temp.check('score within [0,1]',
    (SELECT bool_and(service_gap_score BETWEEN 0 AND 1) FROM district_indicators), true);
