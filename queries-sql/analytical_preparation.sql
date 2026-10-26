-- =========================================================
-- BEAUTYCOMMERCE — CUSTOMER JOURNEY, CONVERSION
-- & RETENTION ANALYTICS
-- =========================================================
-- 05. ANALYTICAL PREPARATION
-- =========================================================
--
-- Purpose:
-- Prepare the cleaned event layer for customer-journey
-- analysis by constructing analytical sessions.
--
-- Why re-sessionize?
--
-- Source user_session values are mostly valid, but diagnostics
-- revealed a long inactivity tail and reuse of source session
-- identifiers across extended periods.
--
-- Therefore:
-- - valid source sessions are retained as source identifiers;
-- - analytical sessions are split when inactivity between
--   consecutive timestamps exceeds 30 minutes.
--
-- The 30-minute threshold is a project-specific analytical
-- rule supported by the observed inactivity-gap distribution.
-- It is NOT treated as a universal session standard.
--
-- Re-sessionization is used for journey/funnel analysis.
-- Customer-level retention and RFM continue to rely on user_id
-- and purchase timestamps.
--
-- =========================================================


-- ---------------------------------------------------------
-- 05.1 Analytical session map
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 unique timestamp within a valid source
--         session-user combination.
--
-- DISTINCT timestamps are used so exact repeated event rows do
-- not artificially create additional session boundaries.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_analytical_session_map AS

WITH valid_timestamps AS (
    SELECT DISTINCT
        user_session
            AS source_user_session,

        user_id,
        event_time_utc

    FROM portofolio_2.vw_events_clean

    WHERE is_valid_session = TRUE
),

ordered_timestamps AS (
    SELECT
        source_user_session,
        user_id,
        event_time_utc,

        LAG(event_time_utc) OVER (
            PARTITION BY
                source_user_session,
                user_id
            ORDER BY event_time_utc
        ) AS previous_event_time

    FROM valid_timestamps
),

session_boundaries AS (
    SELECT
        *,

        CASE
            WHEN previous_event_time IS NULL
                THEN 1

            WHEN event_time_utc
                 - previous_event_time
                 > INTERVAL '30 minutes'
                THEN 1

            ELSE 0
        END AS new_session_flag

    FROM ordered_timestamps
),

session_segments AS (
    SELECT
        *,

        SUM(new_session_flag) OVER (
            PARTITION BY
                source_user_session,
                user_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND CURRENT ROW
        ) AS session_segment

    FROM session_boundaries
)

SELECT
    source_user_session,
    user_id,
    event_time_utc,
    session_segment,

    source_user_session::text
        || '-'
        || session_segment::text
        AS analytical_session_id

FROM session_segments;


CREATE UNIQUE INDEX idx_analytical_session_map_timestamp
ON portofolio_2.mv_analytical_session_map (
    source_user_session,
    user_id,
    event_time_utc
);

CREATE INDEX idx_analytical_session_map_id
ON portofolio_2.mv_analytical_session_map (
    analytical_session_id
);

ANALYZE portofolio_2.mv_analytical_session_map;


-- ---------------------------------------------------------
-- 05.2 Sessionized event layer
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 original event belonging to a valid analytical
--         session.
--
-- Exact repeated source events remain preserved.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_events_sessionized AS

SELECT
    m.analytical_session_id,
    m.session_segment,

    e.user_session
        AS source_user_session,

    e.event_time_utc,
    e.event_type,
    e.product_id,
    e.category_id,
    e.category_code,
    e.brand,
    e.price,
    e.user_id,

    e.is_valid_monetary_purchase,
    e.observed_purchase_value

FROM portofolio_2.vw_events_clean e

JOIN portofolio_2.mv_analytical_session_map m
    ON e.user_session
        = m.source_user_session

   AND e.user_id
        = m.user_id

   AND e.event_time_utc
        = m.event_time_utc

WHERE e.is_valid_session = TRUE;


CREATE INDEX idx_sessionized_session_time
ON portofolio_2.mv_events_sessionized (
    analytical_session_id,
    event_time_utc
);

CREATE INDEX idx_sessionized_user_time
ON portofolio_2.mv_events_sessionized (
    user_id,
    event_time_utc
);

CREATE INDEX idx_sessionized_product
ON portofolio_2.mv_events_sessionized (
    product_id
);

ANALYZE portofolio_2.mv_events_sessionized;


-- ---------------------------------------------------------
-- 05.3 Event-layer reconciliation
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS sessionized_events,

    COUNT(
        DISTINCT analytical_session_id
    ) AS analytical_sessions,

    COUNT(
        DISTINCT user_id
    ) AS unique_users

FROM portofolio_2.mv_events_sessionized;

-- Observed:
-- sessionized_events    = 20,686,257
-- analytical_sessions   = 4,809,955
-- unique_users          = 1,638,714


-- ---------------------------------------------------------
-- 05.4 Session-splitting reconciliation
-- ---------------------------------------------------------
-- Each inactivity gap > 30 minutes creates one additional
-- analytical session.

WITH ordered_events AS (
    SELECT
        user_session,
        user_id,
        event_time AT TIME ZONE 'UTC'
            AS event_time_utc,

        LAG(
            event_time AT TIME ZONE 'UTC'
        ) OVER (
            PARTITION BY
                user_session,
                user_id
            ORDER BY event_time
        ) AS previous_event_time

    FROM (
        SELECT DISTINCT
            user_session,
            user_id,
            event_time

        FROM portofolio_2.events

        WHERE user_session IN (
            SELECT user_session
            FROM portofolio_2.mv_valid_sessions
        )
    ) d
)

SELECT
    COUNT(*) FILTER (
        WHERE previous_event_time IS NOT NULL
          AND event_time_utc
              - previous_event_time
              > INTERVAL '30 minutes'
    ) AS gaps_over_30_minutes

FROM ordered_events;

-- Observed:
-- 274,286 qualifying inactivity gaps
--
-- Therefore:
-- 4,535,669 valid source sessions
-- + 274,286 additional session splits
-- = 4,809,955 analytical sessions


-- ---------------------------------------------------------
-- 05.5 Analytical-session integrity check
-- ---------------------------------------------------------
-- After sessionization, no consecutive timestamps inside one
-- analytical session should be separated by > 30 minutes.

WITH ordered_events AS (
    SELECT
        analytical_session_id,
        event_time_utc,

        LAG(event_time_utc) OVER (
            PARTITION BY analytical_session_id
            ORDER BY event_time_utc
        ) AS previous_event_time

    FROM (
        SELECT DISTINCT
            analytical_session_id,
            event_time_utc

        FROM portofolio_2.mv_events_sessionized
    ) x
)

SELECT
    COUNT(*) AS internal_gaps_over_30_minutes

FROM ordered_events

WHERE previous_event_time IS NOT NULL
  AND event_time_utc
      - previous_event_time
      > INTERVAL '30 minutes';

-- Expected:
-- 0
