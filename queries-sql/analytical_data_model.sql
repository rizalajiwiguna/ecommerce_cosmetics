-- =========================================================
-- BEAUTYCOMMERCE — CUSTOMER JOURNEY, CONVERSION
-- & RETENTION ANALYTICS
-- =========================================================
-- 06. ANALYTICAL DATA MODEL
-- =========================================================
--
-- Purpose:
-- Build reusable analytical summary layers from the
-- sessionized event data.
--
-- Primary analytical grains:
--
-- 1. mv_analytical_session_summary
--    1 row = 1 analytical session
--
-- 2. mv_customer_purchase_summary
--    1 row = 1 user with at least one observed purchase
--
-- Important terminology:
-- - Purchase Events = recorded purchase event rows.
-- - Purchase Sessions = analytical sessions containing
--   at least one purchase event.
-- - Purchase Sessions are NOT confirmed orders because the
--   dataset does not contain an order_id.
-- - Observed Purchase Value includes only positive-price
--   purchase events.
--
-- =========================================================


-- ---------------------------------------------------------
-- 06.1 Analytical session summary
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 analytical session.
--
-- Event-presence fields in this table are descriptive.
-- They are NOT used directly as the sequence-aware funnel.
-- Funnel ordering is constructed separately in 07.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_analytical_session_summary AS

SELECT
    analytical_session_id,
    source_user_session,
    user_id,

    MIN(event_time_utc)
        AS session_start_utc,

    MAX(event_time_utc)
        AS session_end_utc,

    DATE_TRUNC(
        'month',
        MIN(event_time_utc)
    )::date AS session_month,

    EXTRACT(
        EPOCH FROM (
            MAX(event_time_utc)
            - MIN(event_time_utc)
        )
    ) / 60.0 AS session_duration_minutes,

    COUNT(*) AS total_events,

    COUNT(*) FILTER (
        WHERE event_type = 'view'
    ) AS view_events,

    COUNT(*) FILTER (
        WHERE event_type = 'cart'
    ) AS cart_events,

    COUNT(*) FILTER (
        WHERE event_type = 'remove_from_cart'
    ) AS remove_events,

    COUNT(*) FILTER (
        WHERE event_type = 'purchase'
    ) AS purchase_events,

    COUNT(*) FILTER (
        WHERE is_valid_monetary_purchase
    ) AS valid_monetary_purchase_events,

    SUM(observed_purchase_value)
        AS observed_purchase_value,

    BOOL_OR(
        event_type = 'view'
    ) AS has_view,

    BOOL_OR(
        event_type = 'cart'
    ) AS has_cart,

    BOOL_OR(
        event_type = 'remove_from_cart'
    ) AS has_remove,

    BOOL_OR(
        event_type = 'purchase'
    ) AS has_purchase,

    MIN(event_time_utc) FILTER (
        WHERE event_type = 'view'
    ) AS first_view_utc,

    MIN(event_time_utc) FILTER (
        WHERE event_type = 'cart'
    ) AS first_cart_utc,

    MIN(event_time_utc) FILTER (
        WHERE event_type = 'remove_from_cart'
    ) AS first_remove_utc,

    MIN(event_time_utc) FILTER (
        WHERE event_type = 'purchase'
    ) AS first_purchase_utc,

    COUNT(DISTINCT product_id)
        AS distinct_products_interacted,

    COUNT(DISTINCT product_id) FILTER (
        WHERE event_type = 'view'
    ) AS distinct_products_viewed,

    COUNT(DISTINCT product_id) FILTER (
        WHERE event_type = 'cart'
    ) AS distinct_products_carted,

    COUNT(DISTINCT product_id) FILTER (
        WHERE event_type = 'purchase'
    ) AS distinct_products_purchased

FROM portofolio_2.mv_events_sessionized

GROUP BY
    analytical_session_id,
    source_user_session,
    user_id;


-- ---------------------------------------------------------
-- 06.2 Analytical session indexes
-- ---------------------------------------------------------

CREATE UNIQUE INDEX idx_analytical_session_summary_id
ON portofolio_2.mv_analytical_session_summary (
    analytical_session_id
);

CREATE INDEX idx_analytical_session_summary_user
ON portofolio_2.mv_analytical_session_summary (
    user_id
);

CREATE INDEX idx_analytical_session_summary_month
ON portofolio_2.mv_analytical_session_summary (
    session_month
);

ANALYZE portofolio_2.mv_analytical_session_summary;


-- ---------------------------------------------------------
-- 06.3 Analytical session grain validation
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS total_rows,

    COUNT(
        DISTINCT analytical_session_id
    ) AS unique_analytical_sessions,

    COUNT(
        DISTINCT user_id
    ) AS unique_users

FROM portofolio_2.mv_analytical_session_summary;

-- Observed:
-- total_rows                 = 4,809,955
-- unique_analytical_sessions = 4,809,955
-- unique_users               = 1,638,714


-- ---------------------------------------------------------
-- 06.4 Session-level reconciliation
-- ---------------------------------------------------------

SELECT
    SUM(total_events)
        AS total_events,

    SUM(purchase_events)
        AS total_purchase_events,

    SUM(valid_monetary_purchase_events)
        AS valid_monetary_purchase_events,

    ROUND(
        SUM(observed_purchase_value),
        2
    ) AS total_observed_purchase_value

FROM portofolio_2.mv_analytical_session_summary;

-- Expected / observed:
-- total_events                    = 20,686,257
-- total_purchase_events           = 1,286,898
-- valid_monetary_purchase_events  = 1,286,771
-- total_observed_purchase_value   = 6,351,305.66
--
-- Note:
-- The monetary value is slightly lower than the clean-layer
-- total because session-based analysis excludes invalid
-- source sessions.


-- ---------------------------------------------------------
-- 06.5 Session-duration distribution
-- ---------------------------------------------------------
-- Median is preferred over the mean because behavioral
-- session duration has a strongly right-skewed distribution.

SELECT
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY session_duration_minutes
        )::numeric,
        2
    ) AS median_session_minutes,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY session_duration_minutes
        )::numeric,
        2
    ) AS p75_session_minutes,

    ROUND(
        PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY session_duration_minutes
        )::numeric,
        2
    ) AS p95_session_minutes,

    ROUND(
        PERCENTILE_CONT(0.99)
        WITHIN GROUP (
            ORDER BY session_duration_minutes
        )::numeric,
        2
    ) AS p99_session_minutes,

    ROUND(
        MAX(session_duration_minutes)::numeric,
        2
    ) AS max_session_minutes

FROM portofolio_2.mv_analytical_session_summary;

-- Observed:
-- median = 0.00 minutes
-- p75    = 1.18 minutes
-- p95    = 21.03 minutes
-- p99    = 51.53 minutes
-- max    = 522.12 minutes
--
-- A session may exceed 30 minutes in total duration.
-- The sessionization rule applies to inactivity BETWEEN
-- consecutive events, not total elapsed session duration.


-- =========================================================
-- CUSTOMER PURCHASE MODEL
-- =========================================================


-- ---------------------------------------------------------
-- 06.6 Customer purchase summary
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 user with at least one observed purchase event.
--
-- Frequency is represented using analytical purchase
-- sessions rather than orders because order_id is unavailable.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_customer_purchase_summary AS

WITH purchase_sessions AS (
    SELECT
        user_id,
        analytical_session_id,

        MIN(event_time_utc)
            AS purchase_session_time,

        COUNT(*) AS purchase_events,

        COUNT(*) FILTER (
            WHERE is_valid_monetary_purchase
        ) AS valid_monetary_purchase_events,

        SUM(observed_purchase_value)
            AS observed_purchase_value

    FROM portofolio_2.mv_events_sessionized

    WHERE event_type = 'purchase'

    GROUP BY
        user_id,
        analytical_session_id
),

ordered_purchase_sessions AS (
    SELECT
        user_id,
        analytical_session_id,
        purchase_session_time,
        purchase_events,
        valid_monetary_purchase_events,
        observed_purchase_value,

        LAG(purchase_session_time) OVER (
            PARTITION BY user_id
            ORDER BY
                purchase_session_time,
                analytical_session_id
        ) AS previous_purchase_session_time

    FROM purchase_sessions
),

customer_purchase AS (
    SELECT
        user_id,

        COUNT(*)
            AS purchase_sessions,

        SUM(purchase_events)
            AS purchase_events,

        SUM(valid_monetary_purchase_events)
            AS valid_monetary_purchase_events,

        SUM(observed_purchase_value)
            AS observed_purchase_value,

        MIN(purchase_session_time)
            AS first_purchase_utc,

        MAX(purchase_session_time)
            AS last_purchase_utc,

        COUNT(
            DISTINCT purchase_session_time::date
        ) AS active_purchase_days,

        COUNT(
            DISTINCT DATE_TRUNC(
                'month',
                purchase_session_time
            )
        ) AS active_purchase_months,

        AVG(
            EXTRACT(
                EPOCH FROM (
                    purchase_session_time
                    - previous_purchase_session_time
                )
            ) / 86400.0
        ) FILTER (
            WHERE previous_purchase_session_time IS NOT NULL
        ) AS avg_days_between_purchase_sessions

    FROM ordered_purchase_sessions

    GROUP BY user_id
),

product_breadth AS (
    SELECT
        user_id,

        COUNT(DISTINCT product_id)
            AS distinct_products_purchased

    FROM portofolio_2.mv_events_sessionized

    WHERE event_type = 'purchase'

    GROUP BY user_id
)

SELECT
    c.user_id,

    c.first_purchase_utc,
    c.last_purchase_utc,

    c.purchase_sessions,
    c.purchase_events,
    c.valid_monetary_purchase_events,

    c.active_purchase_days,
    c.active_purchase_months,

    p.distinct_products_purchased,

    c.observed_purchase_value,

    c.observed_purchase_value
        / NULLIF(
            c.purchase_sessions,
            0
        ) AS avg_observed_value_per_purchase_session,

    EXTRACT(
        EPOCH FROM (
            c.last_purchase_utc
            - c.first_purchase_utc
        )
    ) / 86400.0
        AS purchase_span_days,

    c.avg_days_between_purchase_sessions,

    CASE
        WHEN c.purchase_sessions >= 2
            THEN TRUE
        ELSE FALSE
    END AS has_repeat_purchase_session,

    CASE
        WHEN c.active_purchase_days >= 2
            THEN TRUE
        ELSE FALSE
    END AS has_repeat_purchase_day

FROM customer_purchase c

LEFT JOIN product_breadth p
    ON c.user_id = p.user_id;

-- ---------------------------------------------------------
-- 06.7 Customer purchase indexes
-- ---------------------------------------------------------

CREATE UNIQUE INDEX idx_customer_purchase_user
ON portofolio_2.mv_customer_purchase_summary (
    user_id
);

CREATE INDEX idx_customer_purchase_first
ON portofolio_2.mv_customer_purchase_summary (
    first_purchase_utc
);

CREATE INDEX idx_customer_purchase_last
ON portofolio_2.mv_customer_purchase_summary (
    last_purchase_utc
);

ANALYZE portofolio_2.mv_customer_purchase_summary;

--06.8 — Customer grain validation
SELECT
    COUNT(*) AS total_rows,

    COUNT(
        DISTINCT user_id
    ) AS unique_users

FROM portofolio_2.mv_customer_purchase_summary;

-- Observed:
-- total_rows   = 110,500
-- unique_users = 110,500

--6.8. Customer purchase reconciliation
SELECT
    COUNT(*) AS purchasing_customers,

    COUNT(*) FILTER (
        WHERE purchase_sessions = 1
    ) AS one_purchase_session_customers,

    COUNT(*) FILTER (
        WHERE purchase_sessions >= 2
    ) AS repeat_purchase_session_customers,

    SUM(purchase_sessions)
        AS total_purchase_sessions,

    SUM(purchase_events)
        AS total_purchase_events,

    SUM(valid_monetary_purchase_events)
        AS valid_monetary_purchase_events,

    ROUND(
        SUM(observed_purchase_value),
        2
    ) AS total_observed_purchase_value

FROM portofolio_2.mv_customer_purchase_summary;

-- Observed:
--
-- purchasing_customers              = 110,500
-- one_purchase_session_customers    = 86,484
-- repeat_purchase_session_customers = 24,016
-- total_purchase_sessions           = 157,573
-- total_purchase_events             = 1,286,898
-- valid_monetary_purchase_events    = 1,286,771
-- total_observed_purchase_value     = 6,351,305.66

--06.10 — Purchase-session frequency distribution
SELECT
    purchase_sessions,

    COUNT(*) AS customers,

    ROUND(
        100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER (),
        2
    ) AS customer_share_pct

FROM portofolio_2.mv_customer_purchase_summary

GROUP BY purchase_sessions

ORDER BY purchase_sessions

LIMIT 15;
