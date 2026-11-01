-- =====================================================================
-- 02_functions.sql — helper functions and triggers
-- =====================================================================

SET search_path = gis, public;

-- ---------------------------------------------------------------------
-- tr_normalize: Turkish-aware name key for matching names from
-- different sources ('ALTINDAĞ' = 'Altındağ', 'Eyüp Sultan' = 'EYÜPSULTAN').
-- PostgreSQL's lower() maps 'I' -> 'i', which is wrong for Turkish
-- ('I' -> 'ı', 'İ' -> 'i'), so the dotted/dotless pairs are translated first.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tr_normalize(s text)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT regexp_replace(
               translate(lower(translate(s, 'IİÂÎÛ', 'ıiaiu')), 'âîû', 'aiu'),
               '[^a-zçğıöşü]', '', 'g')
$$;

COMMENT ON FUNCTION tr_normalize(text) IS
    'Turkish-aware matching key: dotted/dotless i handled, circumflexes folded, spaces and punctuation removed.';

-- ---------------------------------------------------------------------
-- Derived measures: area is always computed from geometry
-- (geodesic area on the WGS84 spheroid, via geography).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_district_area()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.area_km2 := round((ST_Area(NEW.geom::geography) / 1e6)::numeric, 2);
    RETURN NEW;
END
$$;

CREATE TRIGGER district_area_biu
    BEFORE INSERT OR UPDATE OF geom ON district
    FOR EACH ROW EXECUTE FUNCTION trg_district_area();

CREATE OR REPLACE FUNCTION trg_facility_area()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.area_m2 := CASE
        WHEN GeometryType(NEW.geom) IN ('POLYGON', 'MULTIPOLYGON')
        THEN round(ST_Area(NEW.geom::geography)::numeric, 1)
    END;
    RETURN NEW;
END
$$;

CREATE TRIGGER facility_area_biu
    BEFORE INSERT OR UPDATE OF geom ON facility
    FOR EACH ROW EXECUTE FUNCTION trg_facility_area();

-- ---------------------------------------------------------------------
-- district_at(lon, lat): reverse geocoding — which district is this point in?
--   SELECT * FROM gis.district_at(32.8597, 39.9334);   -- Kızılay, Ankara
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION district_at(lon double precision, lat double precision)
RETURNS TABLE (district_id integer, district text, province text)
LANGUAGE sql STABLE
AS $$
    SELECT d.district_id, d.name::text, p.name::text
    FROM   gis.district d
    JOIN   gis.province p USING (province_id)
    WHERE  ST_Intersects(d.geom, ST_SetSRID(ST_MakePoint(lon, lat), 4326))
    LIMIT  1
$$;
