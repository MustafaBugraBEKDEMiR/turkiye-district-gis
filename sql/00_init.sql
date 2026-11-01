-- =====================================================================
-- 00_init.sql — extensions and schemas
-- Rebuilds the database from scratch (idempotent: safe to re-run).
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

-- staging : raw source documents exactly as downloaded (jsonb)
-- gis     : the normalized, constrained core model
-- report  : read-only views / materialized views for analysis
DROP SCHEMA IF EXISTS report  CASCADE;
DROP SCHEMA IF EXISTS gis     CASCADE;
DROP SCHEMA IF EXISTS staging CASCADE;

CREATE SCHEMA staging;
CREATE SCHEMA gis;
CREATE SCHEMA report;

CREATE TABLE staging.raw_document (
    source      text        PRIMARY KEY,          -- e.g. 'geoboundaries_adm2'
    url         text        NOT NULL,
    fetched_at  timestamptz NOT NULL DEFAULT now(),
    doc         jsonb       NOT NULL
);
