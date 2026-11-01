-- =====================================================================
-- 02_spatial.sql — PostGIS queries
-- =====================================================================
SET search_path = gis, report, public;

-- 1. Reverse geocoding: which district is Kızılay Square (Ankara) in?
SELECT * FROM district_at(32.8545, 39.9208);

-- 2. Neighbouring districts of Çankaya (shared boundary)
SELECT n.name AS neighbour, p.name AS province
FROM   district d
JOIN   province dp ON dp.province_id = d.province_id
JOIN   district n  ON n.district_id <> d.district_id
                  AND ST_Intersects(d.geom, n.geom)        -- uses the GiST index
JOIN   province p  ON p.province_id = n.province_id
WHERE  d.name = 'Çankaya' AND dp.name = 'Ankara'
ORDER  BY n.name;

-- 3. Provinces that border Ankara (dissolved province boundaries)
SELECT b.province
FROM   province_summary a
JOIN   province_summary b ON b.province_id <> a.province_id
                         AND ST_Intersects(a.geom, b.geom)
WHERE  a.province = 'Ankara'
ORDER  BY b.province;

-- 4. Districts whose centre lies within 50 km of Kızılay (geodesic distance)
SELECT d.name, p.name AS province,
       round((ST_Distance(ST_PointOnSurface(d.geom)::geography,
                          ST_SetSRID(ST_MakePoint(32.8545, 39.9208), 4326)::geography) / 1000)::numeric, 1) AS km
FROM   district d JOIN province p USING (province_id)
WHERE  ST_DWithin(ST_PointOnSurface(d.geom)::geography,
                  ST_SetSRID(ST_MakePoint(32.8545, 39.9208), 4326)::geography,
                  50000)
ORDER  BY km;

-- 5. K-nearest neighbours with the index-assisted <-> operator:
--    the 5 district centres closest to Kapadokya (Göreme)
SELECT d.name, p.name AS province
FROM   district d JOIN province p USING (province_id)
ORDER  BY d.geom <-> ST_SetSRID(ST_MakePoint(34.8285, 38.6431), 4326)
LIMIT  5;

-- 6. Distance from each province's most populous district to Ankara's
--    Kızılay — a simple "remoteness from the capital" measure
SELECT DISTINCT ON (province) province, district,
       round((ST_Distance(ST_PointOnSurface(geom)::geography,
                          ST_SetSRID(ST_MakePoint(32.8545, 39.9208), 4326)::geography) / 1000)::numeric) AS km_to_ankara
FROM   district_indicators
ORDER  BY province, population DESC;

-- 7. Shape compactness (Polsby–Popper, 1 = circle): least compact districts
SELECT name, province_id,
       round((4 * pi() * ST_Area(geom::geography)
              / power(ST_Perimeter(geom::geography), 2))::numeric, 3) AS polsby_popper
FROM   district
ORDER  BY polsby_popper
LIMIT  10;

-- 8. Extremes: northern-, southern-, eastern-, western-most districts
(SELECT 'north' AS side, name FROM district ORDER BY ST_YMax(geom) DESC LIMIT 1)
UNION ALL
(SELECT 'south', name FROM district ORDER BY ST_YMin(geom)       LIMIT 1)
UNION ALL
(SELECT 'east',  name FROM district ORDER BY ST_XMax(geom) DESC  LIMIT 1)
UNION ALL
(SELECT 'west',  name FROM district ORDER BY ST_XMin(geom)       LIMIT 1);

-- 9. Quality check: computed area vs. official province area
--    (the per-district sum should be close to Türkiye's ~783,500 km²)
SELECT round(sum(area_km2)) AS total_area_km2 FROM district;

-- 10. Topology check: do any districts overlap each other?
SELECT a.name AS district_a, b.name AS district_b,
       round((ST_Area(ST_Intersection(a.geom, b.geom)::geography) / 1e6)::numeric, 3) AS overlap_km2
FROM   district a
JOIN   district b ON a.district_id < b.district_id
                 AND ST_Intersects(a.geom, b.geom)
                 AND ST_Relate(a.geom, b.geom, '2********')   -- interiors overlap
ORDER  BY overlap_km2 DESC
LIMIT  10;

-- 11. Export one province as a GeoJSON FeatureCollection (for web maps)
SELECT json_build_object(
         'type', 'FeatureCollection',
         'features', json_agg(ST_AsGeoJSON(t.*, 'geom', 5)::json))
FROM  (SELECT district, population, density_per_km2, geom
       FROM   district_indicators
       WHERE  province = 'Ankara') t;
