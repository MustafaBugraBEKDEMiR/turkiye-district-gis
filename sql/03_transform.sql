-- =====================================================================
-- 03_transform.sql — staging (raw jsonb) -> core model (gis)
--
-- Sources
--   geoboundaries_adm1 : 81 province polygons   (OSM, ODbL)
--   geoboundaries_adm2 : 973 district polygons  (OSM, ODbL)
--   tuik_adnks         : province & district names and codes, district population
--                        (TÜİK ADNKS). NOTE: the district figures in this file are
--                        the 2021 results (they sum to the official 2021 total of
--                        84,680,273); only the province totals in it are 2022.
--
-- The hard part is joining two sources that have no common key:
--   1. each district polygon gets its province by a SPATIAL join
--      (point-on-surface inside the province polygon);
--   2. inside a province, polygons and TÜİK records are matched by name in
--      three explicit, auditable passes (exact -> alias -> 'Merkez').
-- Every pairing and the pass that produced it is kept in
-- staging.district_match, and the script fails loudly if anything is left.
-- =====================================================================

SET search_path = gis, public;

-- ---------------------------------------------------------------------
-- 1. Typed staging views over the raw documents
-- ---------------------------------------------------------------------
CREATE TABLE staging.adm1 AS
SELECT substr(f -> 'properties' ->> 'shapeISO', 4)::smallint      AS plate,
       f -> 'properties' ->> 'shapeName'                          AS name,
       ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(f -> 'geometry'), 4326)) AS geom
FROM   staging.raw_document, jsonb_array_elements(doc -> 'features') f
WHERE  source = 'geoboundaries_adm1';

CREATE TABLE staging.adm2 AS
SELECT f -> 'properties' ->> 'shapeID'                            AS shape_id,
       f -> 'properties' ->> 'shapeName'                          AS name,
       ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(f -> 'geometry'), 4326)) AS geom
FROM   staging.raw_document, jsonb_array_elements(doc -> 'features') f
WHERE  source = 'geoboundaries_adm2';

CREATE VIEW staging.tuik_province AS
SELECT (p ->> 'plaka_kodu')::smallint            AS plate,
       btrim(p ->> 'il_adi')                     AS name,
       btrim(p ->> 'bolge')                      AS region_name
FROM   staging.raw_document, jsonb_array_elements(doc -> 'data') p
WHERE  source = 'tuik_adnks';

CREATE VIEW staging.tuik_district AS
SELECT (p ->> 'plaka_kodu')::smallint                  AS plate,
       (x ->> 'ilce_kodu')::integer                    AS tuik_code,
       btrim(x ->> 'ilce_adi')                         AS name_upper,
       replace(x ->> 'nufus',       '.', '')::integer  AS total,
       replace(x ->> 'erkek_nufus', '.', '')::integer  AS male,
       replace(x ->> 'kadin_nufus', '.', '')::integer  AS female
FROM   staging.raw_document,
       jsonb_array_elements(doc -> 'data')    p,
       jsonb_array_elements(p -> 'ilceler')   x
WHERE  source = 'tuik_adnks';

-- ---------------------------------------------------------------------
-- 2. Provinces
-- ---------------------------------------------------------------------
INSERT INTO province (province_id, name, region_id)
SELECT t.plate, t.name, r.region_id
FROM   staging.tuik_province t
JOIN   region r ON r.name_tr = t.region_name;

-- ---------------------------------------------------------------------
-- 3. Spatial join: which province is each district polygon in?
-- ---------------------------------------------------------------------
ALTER TABLE staging.adm2 ADD COLUMN plate smallint;

UPDATE staging.adm2 d
SET    plate = p.plate
FROM   staging.adm1 p
WHERE  ST_Intersects(p.geom, ST_PointOnSurface(d.geom));

-- ---------------------------------------------------------------------
-- 4. Name matching, in three passes
-- ---------------------------------------------------------------------
-- Known spelling differences between OSM and TÜİK (English names,
-- missing Turkish characters, typos). display_name is the correct
-- Turkish spelling used in gis.district.
CREATE TABLE staging.name_alias (
    plate         smallint NOT NULL,
    osm_name      text     NOT NULL,
    tuik_name     text     NOT NULL,
    display_name  text     NOT NULL,
    PRIMARY KEY (plate, osm_name)
);

INSERT INTO staging.name_alias VALUES
    ( 7, 'İbradi',          'İBRADI',    'İbradı'),
    (17, 'Imbros',          'GÖKÇEADA',  'Gökçeada'),
    (17, 'Ayvacik',         'AYVACIK',   'Ayvacık'),
    (24, 'Ilıç',            'İLİÇ',      'İliç'),
    (34, 'Prince Islands',  'ADALAR',    'Adalar'),
    (43, 'Gediz Merkez',    'GEDİZ',     'Gediz'),
    (51, 'Ulukisla',        'ULUKIŞLA',  'Ulukışla'),
    (71, 'Karakeçeli',      'KARAKEÇİLİ','Karakeçili');

CREATE TABLE staging.district_match (
    shape_id      text     PRIMARY KEY,
    tuik_code     integer  NOT NULL UNIQUE,
    display_name  text     NOT NULL,
    method        text     NOT NULL
                  CHECK (method IN ('exact', 'alias', 'merkez'))
);

-- Pass 1: exact match on the Turkish-aware key, within the same province
INSERT INTO staging.district_match
SELECT a.shape_id, t.tuik_code, a.name, 'exact'
FROM   staging.adm2 a
JOIN   staging.tuik_district t
       ON  t.plate = a.plate
       AND tr_normalize(t.name_upper) = tr_normalize(a.name);

-- Pass 2: curated aliases
INSERT INTO staging.district_match
SELECT a.shape_id, t.tuik_code, al.display_name, 'alias'
FROM   staging.adm2 a
JOIN   staging.name_alias al ON al.plate = a.plate AND al.osm_name = a.name
JOIN   staging.tuik_district t
       ON t.plate = a.plate AND t.name_upper = al.tuik_name
WHERE  NOT EXISTS (SELECT 1 FROM staging.district_match m WHERE m.shape_id = a.shape_id);

-- Pass 3: central districts. TÜİK calls them 'MERKEZ'; OSM uses
-- 'Bolu Merkez', 'Niğde (merkez)', 'Ardahan', 'Giresun District', ...
-- Rule: the remaining polygon whose name contains 'merkez' or starts
-- with the province name.
INSERT INTO staging.district_match
SELECT a.shape_id, t.tuik_code, 'Merkez', 'merkez'
FROM   staging.adm2 a
JOIN   province p ON p.province_id = a.plate
JOIN   staging.tuik_district t ON t.plate = a.plate AND t.name_upper = 'MERKEZ'
WHERE  NOT EXISTS (SELECT 1 FROM staging.district_match m WHERE m.shape_id = a.shape_id)
  AND  (tr_normalize(a.name) LIKE '%merkez%'
        OR tr_normalize(a.name) LIKE tr_normalize(p.name) || '%');

-- Fail loudly if anything is left unmatched on either side
DO $$
DECLARE
    n_poly   int;
    n_tuik   int;
BEGIN
    SELECT count(*) INTO n_poly FROM staging.adm2 a
    WHERE NOT EXISTS (SELECT 1 FROM staging.district_match m WHERE m.shape_id = a.shape_id);
    SELECT count(*) INTO n_tuik FROM staging.tuik_district t
    WHERE NOT EXISTS (SELECT 1 FROM staging.district_match m WHERE m.tuik_code = t.tuik_code);
    IF n_poly > 0 OR n_tuik > 0 THEN
        RAISE EXCEPTION 'district matching incomplete: % polygons, % TÜİK records unmatched',
                        n_poly, n_tuik;
    END IF;
    RAISE NOTICE 'district matching: % exact, % alias, % merkez',
        (SELECT count(*) FROM staging.district_match WHERE method = 'exact'),
        (SELECT count(*) FROM staging.district_match WHERE method = 'alias'),
        (SELECT count(*) FROM staging.district_match WHERE method = 'merkez');
END $$;

-- ---------------------------------------------------------------------
-- 5. Load the core tables
-- ---------------------------------------------------------------------
INSERT INTO district (tuik_code, name, province_id, geom, osm_shape_id)
SELECT t.tuik_code, m.display_name, t.plate,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(a.geom), 3)),
       a.shape_id
FROM   staging.district_match m
JOIN   staging.adm2          a USING (shape_id)
JOIN   staging.tuik_district t USING (tuik_code)
ORDER  BY t.plate, m.display_name;

INSERT INTO district_population (district_id, year, total, male, female, source)
SELECT d.district_id, 2021, t.total, t.male, t.female, 'TÜİK ADNKS 2021'
FROM   district d
JOIN   staging.tuik_district t USING (tuik_code);

ANALYZE district;
ANALYZE district_population;
