/*
A. Purpose:
-Measure customer progression through the observed
-View → Cart → Purchase journey using analytical sessions.
B. Grain:1 row = 1 analytical session
C. Method: Funnel stages are sequence-aware.
D. Important:
-Funnel stages measure observed behavioral progression.
-Funnel leakage does NOT identify causal reasons.
-remove_from_cart is analyzed separately and is not treated as a mandatory funnel stage.
*/

--1 Supporting index
CREATE INDEX IF NOT EXISTS idx_sessionized_session_time_type
ON portofolio_2.mv_events_sessionized (
    analytical_session_id,
    event_time_utc,
    event_type
);

ANALYZE portofolio_2.mv_events_sessionized;

--2. Sequence-aware session funnel
CREATE MATERIALIZED VIEW
    portofolio_2.mv_session_funnel AS
WITH timestamp_events AS (
    SELECT
        analytical_session_id,
        user_id,
        event_time_utc,
        BOOL_OR(event_type = 'view') AS has_view_at_ts,
        BOOL_OR(event_type = 'cart') AS has_cart_at_ts,
        BOOL_OR(event_type = 'remove_from_cart') AS has_remove_at_ts,
        BOOL_OR(event_type = 'purchase') AS has_purchase_at_ts
    FROM portofolio_2.mv_events_sessionized
    GROUP BY
        analytical_session_id,
        user_id,
        event_time_utc
),
after_view AS (
    SELECT
        *,
        BOOL_OR(has_view_at_ts) OVER (
            PARTITION BY analytical_session_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND CURRENT ROW
        ) AS seen_view
    FROM timestamp_events
),
after_cart AS (
    SELECT
        *,
        BOOL_OR(
            has_cart_at_ts AND seen_view) OVER (
        PARTITION BY analytical_session_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND CURRENT ROW ) AS seen_qualified_cart
    FROM after_view
),
session_stages AS (
    SELECT
        analytical_session_id,
        user_id,
        MIN(event_time_utc) AS session_start_utc,
        MAX(event_time_utc) AS session_end_utc,
        BOOL_OR(has_view_at_ts) AS has_any_view,
        BOOL_OR(has_cart_at_ts)MAS has_any_cart,
        BOOL_OR(has_remove_at_ts) AS has_any_remove,
        BOOL_OR(has_purchase_at_ts) AS has_any_purchase,
        MIN(event_time_utc) FILTER (
            WHERE has_view_at_ts) AS first_view_utc,
        MIN(event_time_utc) FILTER (
            WHERE has_cart_at_ts AND seen_view) AS first_cart_after_view_utc,
        MIN(event_time_utc) FILTER (
            WHERE has_purchase_at_ts AND seen_qualified_cart) AS first_purchase_after_cart_utc
    FROM after_cart
    GROUP BY
        analytical_session_id,
        user_id
)
SELECT
    analytical_session_id,
    user_id,
    session_start_utc,
    session_end_utc,
    DATE_TRUNC('month', session_start_utc)::date AS session_month,
    has_any_view,
    has_any_cart,
    has_any_remove,
    has_any_purchase,
    first_view_utc,
    first_cart_after_view_utc,
    first_purchase_after_cart_utc,
    first_view_utc IS NOT NULL AS reached_view,
    first_cart_after_view_utc IS NOT NULL AS reached_cart_after_view,
    first_purchase_after_cart_utc IS NOT NULL AS reached_purchase_after_cart,
    EXTRACT(
        EPOCH FROM (
            first_cart_after_view_utc - first_view_utc)) / 60.0 AS minutes_view_to_cart,
    EXTRACT(
        EPOCH FROM (
            first_purchase_after_cart_utc - first_cart_after_view_utc)) / 60.0 AS minutes_cart_to_purchase
FROM session_stages;

--3. Funnel indexes
CREATE UNIQUE INDEX idx_session_funnel_session
ON portofolio_2.mv_session_funnel (
    analytical_session_id
);

CREATE INDEX idx_session_funnel_user
ON portofolio_2.mv_session_funnel (
    user_id
);

CREATE INDEX idx_session_funnel_month
ON portofolio_2.mv_session_funnel (
    session_month
);

ANALYZE portofolio_2.mv_session_funnel;

--4. Funnel grain and stage validation
SELECT
    COUNT(*) AS total_sessions,
    COUNT(DISTINCT analytical_session_id) AS unique_sessions,
    COUNT(*) FILTER (WHERE reached_view) AS view_stage_sessions,
    COUNT(*) FILTER (WHERE reached_cart_after_view) AS cart_after_view_sessions,
    COUNT(*) FILTER (WHERE reached_purchase_after_cart) AS purchase_after_cart_sessions
FROM portofolio_2.mv_session_funnel;
/*
Observed:
-total_sessions               = 4,809,955
-unique_sessions              = 4,809,955
-view_stage_sessions          = 4,500,535
-cart_after_view_sessions     =   745,616
-purchase_after_cart_sessions =    95,842
*/

--5. Alternative observed paths
SELECT
    COUNT(*) FILTER (
        WHERE has_any_cart
          AND NOT reached_cart_after_view) AS cart_without_prior_view,
    COUNT(*) FILTER (
        WHERE has_any_purchase
          AND NOT reached_purchase_after_cart) AS purchase_without_qualified_funnel,
    COUNT(*) FILTER (
        WHERE has_any_remove) AS sessions_with_remove
FROM portofolio_2.mv_session_funnel;
/*
A. Observed:
-cart_without_prior_view             = 303,562
-purchase_without_qualified_funnel   = 61,731
-sessions_with_remove                = 517,282

B. Interpretation:
-The full View → Cart → Purchase path is not the only
-observed behavioral path in the source data.
*/

--6. Overall funnel KPI
WITH funnel AS (
    SELECT
        COUNT(*) FILTER (WHERE reached_view) AS view_sessions,
        COUNT(*) FILTER (WHERE reached_cart_after_view) AS cart_sessions,
        COUNT(*) FILTER (WHERE reached_purchase_after_cart) AS purchase_sessions
    FROM portofolio_2.mv_session_funnel
)
SELECT
    view_sessions,
    cart_sessions,
    purchase_sessions,
    ROUND(100.0 * cart_sessions/ NULLIF(view_sessions, 0),2) AS view_to_cart_rate,
    ROUND(100.0 * purchase_sessions/ NULLIF(cart_sessions, 0),2) AS cart_to_purchase_rate,
    ROUND(100.0 * purchase_sessions/ NULLIF(view_sessions, 0),2) AS view_to_purchase_rate,
    ROUND(100.0 * (view_sessions - cart_sessions)/ NULLIF(view_sessions, 0),2) AS view_to_cart_leakage,
    ROUND(100.0 * (cart_sessions - purchase_sessions)/ NULLIF(cart_sessions, 0),2) AS cart_to_purchase_leakage
FROM funnel;
/*
Observed:
-View → Cart         = 16.57%
-Cart → Purchase     = 12.85%
-View → Purchase     =  2.13%
-View → Cart leakage = 83.43%
-Cart → Purchase
-leakage             = 87.15%
*/

--7. Monthly funnel performance
WITH monthly_funnel AS (
    SELECT
        session_month,
        COUNT(*) FILTER(WHERE reached_view) AS view_sessions,
        COUNT(*) FILTER(WHERE reached_cart_after_view) AS cart_sessions,
        COUNT(*) FILTER(WHERE reached_purchase_after_cart) AS purchase_sessions
    FROM portofolio_2.mv_session_funnel
    GROUP BY session_month
)
SELECT
    session_month,
    view_sessions,
    cart_sessions,
    purchase_sessions,
    ROUND(100.0 * cart_sessions/ NULLIF(view_sessions, 0), 2) AS view_to_cart_rate,
    ROUND(100.0 * purchase_sessions/ NULLIF(cart_sessions, 0),2) AS cart_to_purchase_rate,
    ROUND(100.0 * purchase_sessions/ NULLIF(view_sessions, 0), 2) AS view_to_purchase_rate
FROM monthly_funnel
ORDER BY session_month;
/*
Observed:
-Month     V→C      C→P      V→P
-Oct      21.08%    9.87%    2.08%
-Nov      17.06%   14.09%    2.40%
-Dec      14.59%   14.66%    2.14%
-Jan      15.25%   13.64%    2.08%
-Feb      14.95%   12.99%    1.94%
*/

--8. Sequence-aware remove-from-cart behavior
WITH timestamp_events AS (
    SELECT
        analytical_session_id,
        event_time_utc,
        BOOL_OR(event_type = 'cart') AS has_cart_at_ts,
        BOOL_OR(event_type = 'remove_from_cart') AS has_remove_at_ts,
        BOOL_OR(event_type = 'purchase') AS has_purchase_at_ts
    FROM portofolio_2.mv_events_sessionized
    GROUP BY
        analytical_session_id,
        event_time_utc
),
cart_history AS (
    SELECT
        *,

        BOOL_OR(has_cart_at_ts) OVER (
            PARTITION BY analytical_session_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS seen_cart
    FROM timestamp_events
),
remove_history AS (
    SELECT
        *,
        BOOL_OR(
            has_remove_at_ts AND seen_cart) OVER (
            PARTITION BY analytical_session_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS seen_remove_after_cart
    FROM cart_history
),
session_behavior AS (
    SELECT
        analytical_session_id,
        BOOL_OR(has_remove_at_ts AND seen_cart) AS has_remove_after_cart,
        BOOL_OR(has_purchase_at_ts AND seen_remove_after_cart) AS has_purchase_after_remove
    FROM remove_history
    GROUP BY analytical_session_id
)
SELECT
    COUNT(*) FILTER(WHERE has_remove_after_cart) AS remove_after_cart_sessions,
    COUNT(*) FILTER(WHERE has_remove_after_cart AND has_purchase_after_remove) AS purchase_after_remove_sessions,
    COUNT(*) FILTER(WHERE has_remove_after_cartAND NOT has_purchase_after_remove) AS no_purchase_after_remove_sessions,
    ROUND(
        100.0 * COUNT(*) FILTER(
            WHERE has_remove_after_cart AND has_purchase_after_remove)/NULLIF(COUNT(*) FILTER(WHERE has_remove_after_cart),0), 2) AS purchase_after_remove_rate
FROM session_behavior;
--Observed:
--remove_after_cart_sessions       = 351,671
--purchase_after_remove_sessions   =  79,511
--no_purchase_after_remove         = 272,160
--purchase_after_remove_rate       = 22.61%
--Do NOT interpret the remaining 77.39% as confirmed cart abandonment

--07.9 Funnel timing
SELECT
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY minutes_view_to_cart) FILTER(WHERE reached_cart_after_view)::numeric, 2) AS median_view_to_cart_minutes,
    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY minutes_view_to_cart) FILTER(WHERE reached_cart_after_view)::numeric,2) AS p75_view_to_cart_minutes,
    ROUND(
        PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY minutes_view_to_cart) FILTER(WHERE reached_cart_after_view)::numeric,2) AS p95_view_to_cart_minutes,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY minutes_cart_to_purchase) FILTER(WHERE reached_purchase_after_cart)::numeric,2) AS median_cart_to_purchase_minutes,
    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY minutes_cart_to_purchase) FILTER(WHERE reached_purchase_after_cart)::numeric,2) AS p75_cart_to_purchase_minutes,
    ROUND(
        PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY minutes_cart_to_purchase) FILTER(WHERE reached_purchase_after_cart)::numeric,2) AS p95_cart_to_purchase_minutes
FROM portofolio_2.mv_session_funnel;
/*
Observed:
-View → Cart
-Median =  1.33 min
-P75    =  4.03 min
-P95    = 15.77 min

-Cart → Purchase
-Median = 11.97 min
-P75    = 26.05 min
-P95    = 63.48 min

-- BUSINESS INTERPRETATION
1. The largest proportional funnel leakage is observed after cart.
2. View → Cart performance weakened materially across the observation period.
3. Cart → Purchase performance improved after October,before weakening again toward February.
4. remove_from_cart is not a terminal state: 22.61% of sessions with an observed cart → remove sequence later recorded a purchase in the same analytical session.
5. The dataset does not contain sufficient evidence to attribute leakage to checkout UX, shipping, payment, inventory, pricing, or advertising.
*/
