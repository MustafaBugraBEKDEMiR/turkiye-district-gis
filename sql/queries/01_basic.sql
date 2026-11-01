-- =====================================================================
-- 01_basic.sql — the original MIS533 course queries, rewritten for the
-- new schema (and fixed: the original #9 had a duplicated GROUP BY,
-- #7 did not aggregate, and "most populated district" was impossible
-- because districts had no population column).
-- =====================================================================
SET search_path = gis, report, public;

-- 1. List all provinces with their region
SELECT p.province_id AS plate, p.name AS province, r.name_en AS region
FROM   province p JOIN region r USING (region_id)
ORDER  BY p.province_id;

-- 2. List all districts with their province names
SELECT d.name AS district, p.name AS province
FROM   district d JOIN province p USING (province_id)
ORDER  BY p.name, d.name;

-- 3. Districts larger than 3,000 km²
SELECT d.name, p.name AS province, d.area_km2
FROM   district d JOIN province p USING (province_id)
WHERE  d.area_km2 > 3000
ORDER  BY d.area_km2 DESC;

-- 4. Provinces with population over 5 million
SELECT province, population
FROM   report.province_summary
WHERE  population > 5000000
ORDER  BY population DESC;

-- 5. The most populated district in Türkiye
SELECT d.name, p.name AS province, dp.total
FROM   district_population dp
JOIN   district d USING (district_id)
JOIN   province p USING (province_id)
WHERE  dp.year = 2021
ORDER  BY dp.total DESC
LIMIT  1;

-- 6. Average district population per province (top 10)
SELECT p.name AS province, round(avg(dp.total)) AS avg_district_population
FROM   district_population dp
JOIN   district d USING (district_id)
JOIN   province p USING (province_id)
WHERE  dp.year = 2021
GROUP  BY p.name
ORDER  BY avg_district_population DESC
LIMIT  10;

-- 7. Total population per province (aggregated from districts)
SELECT p.name AS province, sum(dp.total) AS population
FROM   district_population dp
JOIN   district d USING (district_id)
JOIN   province p USING (province_id)
WHERE  dp.year = 2021
GROUP  BY p.name
ORDER  BY population DESC;

-- 8. Number of districts per province
SELECT p.name AS province, count(*) AS districts
FROM   province p JOIN district d USING (province_id)
GROUP  BY p.name
ORDER  BY districts DESC, province;

-- 9. Provinces where EVERY district has fewer than 50,000 people
SELECT p.name
FROM   province p
WHERE  NOT EXISTS (
    SELECT 1
    FROM   district d JOIN district_population dp USING (district_id)
    WHERE  d.province_id = p.province_id AND dp.year = 2021 AND dp.total >= 50000)
ORDER  BY p.name;

-- 10. Largest district (by area) in each province  — DISTINCT ON
SELECT DISTINCT ON (p.name) p.name AS province, d.name AS largest_district, d.area_km2
FROM   district d JOIN province p USING (province_id)
ORDER  BY p.name, d.area_km2 DESC;

-- 11. Top 3 districts by population in each province — window function
SELECT province, district, population, pop_rank_in_province
FROM   report.district_indicators
WHERE  pop_rank_in_province <= 3
ORDER  BY province, pop_rank_in_province;

-- 12. Gender ratio (men per 100 women), most unbalanced districts
SELECT d.name, p.name AS province, dp.male, dp.female,
       round(100.0 * dp.male / dp.female, 1) AS men_per_100_women
FROM   district_population dp
JOIN   district d USING (district_id)
JOIN   province p USING (province_id)
WHERE  dp.year = 2021
ORDER  BY abs(100.0 * dp.male / dp.female - 100) DESC
LIMIT  10;

-- 13. Population by region with share of national total
SELECT * FROM report.region_summary ORDER BY population DESC;
