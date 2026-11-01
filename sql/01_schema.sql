-- =====================================================================
-- 01_schema.sql — core relational + spatial model (schema "gis")
--
--   region 1 ──< province 1 ──< district 1 ──< district_population
--                                    │
--                                    └── (spatial) ──< facility >── facility_type
--
-- Design notes
--  * Geometry is the single source of truth for location and size.
--    area_km2 is derived from geom by a trigger (never typed by hand),
--    and province boundaries are derived from their districts (see
--    report.province_summary) instead of being stored twice.
--  * Population is time-dependent, so it lives in its own table keyed by
--    (district_id, year) instead of being a column of district.
--  * Facilities (schools, parks) are stored as individual features; counts
--    per district are computed with spatial joins, not stored.
-- =====================================================================

SET search_path = gis, public;

-- ---------------------------------------------------------------------
-- Lookup: the 7 geographical regions of Türkiye
-- ---------------------------------------------------------------------
CREATE TABLE region (
    region_id   smallint     PRIMARY KEY,
    name_tr     varchar(40)  NOT NULL UNIQUE,
    name_en     varchar(40)  NOT NULL UNIQUE
);

-- ---------------------------------------------------------------------
-- Province (il). province_id = official licence-plate code (01–81).
-- ---------------------------------------------------------------------
CREATE TABLE province (
    province_id     smallint     PRIMARY KEY
                                 CHECK (province_id BETWEEN 1 AND 81),
    name            varchar(60)  NOT NULL UNIQUE,
    region_id       smallint     NOT NULL REFERENCES region (region_id)
);

-- ---------------------------------------------------------------------
-- District (ilçe)
-- ---------------------------------------------------------------------
CREATE TABLE district (
    district_id     serial       PRIMARY KEY,
    tuik_code       integer      NOT NULL UNIQUE,      -- TÜİK / NVİ district code
    name            varchar(60)  NOT NULL,
    province_id     smallint     NOT NULL
                                 REFERENCES province (province_id)
                                 ON UPDATE CASCADE ON DELETE RESTRICT,
    geom            geometry(MultiPolygon, 4326) NOT NULL,
    area_km2        numeric(10,2),                     -- maintained by trigger
    osm_shape_id    varchar(40)  UNIQUE,               -- geoBoundaries shapeID (lineage)

    CONSTRAINT district_name_unique_in_province UNIQUE (province_id, name),
    CONSTRAINT district_geom_valid  CHECK (ST_IsValid(geom)),
    CONSTRAINT district_area_pos    CHECK (area_km2 IS NULL OR area_km2 > 0)
);

-- ---------------------------------------------------------------------
-- Population by district and year (TÜİK ADNKS)
-- ---------------------------------------------------------------------
CREATE TABLE district_population (
    district_id     integer      NOT NULL
                                 REFERENCES district (district_id) ON DELETE CASCADE,
    year            smallint     NOT NULL CHECK (year BETWEEN 1990 AND 2100),
    total           integer      NOT NULL CHECK (total >= 0),
    male            integer      NOT NULL CHECK (male  >= 0),
    female          integer      NOT NULL CHECK (female >= 0),
    source          varchar(80)  NOT NULL DEFAULT 'TÜİK ADNKS',

    PRIMARY KEY (district_id, year),
    CONSTRAINT population_sum_matches CHECK (male + female = total)
);

-- ---------------------------------------------------------------------
-- Facilities (public services) — loaded from OpenStreetMap
-- ---------------------------------------------------------------------
CREATE TABLE facility_type (
    type_code       varchar(20)  PRIMARY KEY,           -- 'school', 'park'
    label_en        varchar(40)  NOT NULL,
    label_tr        varchar(40)  NOT NULL,
    osm_filter      text         NOT NULL               -- documentation of the OSM tag
);

CREATE TABLE facility (
    facility_id     bigserial    PRIMARY KEY,
    type_code       varchar(20)  NOT NULL REFERENCES facility_type (type_code),
    osm_ref         varchar(30)  NOT NULL UNIQUE,       -- e.g. 'way/123456'
    name            varchar(200),
    geom            geometry(Geometry, 4326) NOT NULL,
    area_m2         numeric(14,1),                      -- maintained by trigger (polygons)

    CONSTRAINT facility_geom_type CHECK (
        GeometryType(geom) IN ('POINT', 'POLYGON', 'MULTIPOLYGON')),
    CONSTRAINT facility_geom_valid CHECK (ST_IsValid(geom))
);

-- ---------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------
CREATE INDEX district_geom_gix    ON district USING gist (geom);
CREATE INDEX district_province_ix ON district (province_id);
CREATE INDEX facility_geom_gix    ON facility USING gist (geom);
CREATE INDEX facility_type_ix     ON facility (type_code);

-- Reference data -------------------------------------------------------
INSERT INTO region (region_id, name_tr, name_en) VALUES
    (1, 'Marmara',           'Marmara'),
    (2, 'Ege',               'Aegean'),
    (3, 'Akdeniz',           'Mediterranean'),
    (4, 'İç Anadolu',        'Central Anatolia'),
    (5, 'Karadeniz',         'Black Sea'),
    (6, 'Doğu Anadolu',      'Eastern Anatolia'),
    (7, 'Güneydoğu Anadolu', 'Southeastern Anatolia');

INSERT INTO facility_type (type_code, label_en, label_tr, osm_filter) VALUES
    ('school', 'School', 'Okul', 'amenity=school'),
    ('park',   'Park',   'Park', 'leisure=park');
