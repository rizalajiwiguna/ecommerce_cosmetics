/*
A. Purpose:
Create the PostgreSQL schema and raw event table used
throughout the BeautyCommerce analytical workflow.

B. Raw table grain:
1 row = 1 recorded behavioral event

C. Observation window:
October 2019 — February 2020

D. Important:
-raw source data is preserved without deduplication.
-no primary key is assigned because event-level uniqueness
-cannot be established from the available fields.
-event_time is stored as TIMESTAMPTZ.
*/


--1. Create project schema
CREATE SCHEMA portofolio_2;
SET search_path TO portofolio_2, public;


--2. Create raw events table
CREATE TABLE portofolio_2.events (
    event_time      TIMESTAMPTZ,
    event_type      VARCHAR(30),
    product_id      BIGINT,
    category_id     BIGINT,
    category_code   TEXT,
    brand           TEXT,
    price           NUMERIC(12,2),
    user_id         BIGINT,
    user_session    UUID
);

-- 3. Table documentation
COMMENT ON TABLE portofolio_2.events IS 'Raw behavioral event data for the BeautyCommerce portfolio project.';
COMMENT ON COLUMN portofolio_2.events.event_time IS 'Timestamp of the recorded event.';
COMMENT ON COLUMN portofolio_2.events.event_type IS 'Observed behavioral event: view, cart, remove_from_cart, or purchase.';
COMMENT ON COLUMN portofolio_2.events.product_id IS 'Source product identifier.';
COMMENT ON COLUMN portofolio_2.events.category_id IS 'Source category identifier recorded at event time.';
COMMENT ON COLUMN portofolio_2.events.category_code IS 'Human-readable category code when available; highly sparse in the source data.';
COMMENT ON COLUMN portofolio_2.events.brand IS 'Brand recorded at event time when available.';
COMMENT ON COLUMN portofolio_2.events.price IS 'Price value recorded on the event. Monetary interpretation is validated later.';
COMMENT ON COLUMN portofolio_2.events.user_id IS 'Source user identifier.';
COMMENT ON COLUMN portofolio_2.events.user_session IS 'Source session identifier. Session validity is assessed during data quality validation.';

--4. import performance index
CREATE INDEX idx_events_session_user
ON portofolio_2.events (ser_session, user_id);

CREATE INDEX IF NOT EXISTS idx_events_session_time
ON portofolio_2.events (user_session, event_time);

CREATE INDEX IF NOT EXISTS idx_events_user_time
ON portofolio_2.events (user_id, event_time);

--5 Update PostgreSQL planner statistics
ANALYZE portofolio_2.events;

--6 Import validation
SELECT
    COUNT(*) AS total_raw_events
FROM portofolio_2.events;

-- result:
-- 20,692,840 rows
