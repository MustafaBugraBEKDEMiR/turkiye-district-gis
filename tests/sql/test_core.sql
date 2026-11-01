-- =====================================================================
-- test_core.sql — data & schema assertions (run by tests/run_tests.py)
-- Every check raises an exception on failure.
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

-- ---- counts --------------------------------------------------------------
SELECT pg_temp.check('81 provinces',  (SELECT count(*) FROM province), 81::bigint);
SELECT pg_temp.check('973 districts', (SELECT count(*) FROM district), 973::bigint);
SELECT pg_temp.check('7 regions',     (SELECT count(*) FROM region),   7::bigint);
SELECT pg_temp.check('every district has population',
    (SELECT count(*) FROM district d
     WHERE NOT EXISTS (SELECT 1 FROM district_population p WHERE p.district_id = d.district_id)),
    0::bigint);

-- ---- population matches published TÜİK ADNKS 2021 figures -----------------
SELECT pg_temp.check('Türkiye total 2021',
    (SELECT sum(total) FROM district_population WHERE year = 2021), 84680273::bigint);
SELECT pg_temp.check('Türkiye male 2021',
    (SELECT sum(male)  FROM district_population WHERE year = 2021), 42428101::bigint);
SELECT pg_temp.check('İstanbul 2021',
    (SELECT population::bigint FROM province_summary WHERE province = 'İstanbul'), 15840900::bigint);
SELECT pg_temp.check('Ankara 2021',
    (SELECT population::bigint FROM province_summary WHERE province = 'Ankara'), 5747325::bigint);
SELECT pg_temp.check('Eastern Anatolia region 2021',
    (SELECT population::bigint FROM region_summary WHERE region = 'Eastern Anatolia'), 6038331::bigint);

-- ---- geometry ------------------------------------------------------------
SELECT pg_temp.check('all district geometries valid',
    (SELECT bool_and(ST_IsValid(geom)) FROM district), true);
SELECT pg_temp.check('total area within 1% of 783,562 km² (incl. lakes)',
    (SELECT abs(sum(area_km2) - 783562) < 7836 FROM district), true);
SELECT pg_temp.check('Kızılay is in Çankaya',
    (SELECT district FROM district_at(32.8545, 39.9208)), 'Çankaya');
SELECT pg_temp.check('Sultanahmet is in Fatih',
    (SELECT district FROM district_at(28.9768, 41.0054)), 'Fatih');
SELECT pg_temp.check('a point in the sea is in no district',
    (SELECT count(*) FROM district_at(33.0, 35.0)), 0::bigint);
SELECT pg_temp.check('Ankara borders 7 provinces',
    (SELECT count(*) FROM province_summary a JOIN province_summary b
       ON a.province_id <> b.province_id AND ST_Intersects(a.geom, b.geom)
     WHERE a.province = 'Ankara'), 7::bigint);

-- ---- functions -----------------------------------------------------------
SELECT pg_temp.check('tr_normalize dotted/dotless I',
    tr_normalize('ALTINDAĞ') = tr_normalize('Altındağ') AND
    tr_normalize('İZMİR')    = tr_normalize('İzmir'), true);
SELECT pg_temp.check('tr_normalize circumflex + spaces',
    tr_normalize('Şarkîkaraağaç') = tr_normalize('ŞARKİKARAAĞAÇ') AND
    tr_normalize('Eyüp Sultan')   = tr_normalize('EYÜPSULTAN'), true);

-- ---- constraints & triggers (inside a transaction that is rolled back) ----
BEGIN;
DO $$
BEGIN
    BEGIN
        INSERT INTO district_population VALUES
            ((SELECT min(district_id) FROM district), 2030, 100, 60, 50, 'test');
        RAISE EXCEPTION 'FAIL: male+female<>total was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'ok   population_sum_matches rejects bad row';
    END;
    BEGIN
        INSERT INTO province VALUES (82, 'Nowhere', 1);
        RAISE EXCEPTION 'FAIL: plate 82 was accepted';
    EXCEPTION WHEN check_violation THEN
        RAISE NOTICE 'ok   province_id must be 1..81';
    END;
    BEGIN
        DELETE FROM province WHERE province_id = 6;
        RAISE EXCEPTION 'FAIL: deleting a province with districts was allowed';
    EXCEPTION WHEN foreign_key_violation THEN
        RAISE NOTICE 'ok   ON DELETE RESTRICT protects districts';
    END;
END $$;
-- trigger recomputes area when geometry changes
UPDATE district SET geom = ST_Multi(ST_Buffer(ST_SetSRID(ST_MakePoint(32.85, 39.92), 4326), 0.01))
WHERE  name = 'Çankaya';
SELECT pg_temp.check('area trigger fires on geom update',
    (SELECT area_km2 BETWEEN 2 AND 4 FROM district WHERE name = 'Çankaya'), true);
ROLLBACK;
