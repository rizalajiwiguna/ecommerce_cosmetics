-- =========================================================
-- BEAUTYCOMMERCE — CUSTOMER JOURNEY, CONVERSION
-- & RETENTION ANALYTICS
-- =========================================================
-- 09. CUSTOMER BEHAVIOR
-- =========================================================
--
-- Purpose:
-- Compare observed behavioral intensity across users who
-- purchase and users who do not, then examine the journey
-- toward each buyer's first observed purchase.
--
-- Key distinction:
-- "Buyer" means a user with at least one observed purchase
-- during the dataset window.
--
-- First observed purchase != first-ever purchase.
--
-- =========================================================


-- ---------------------------------------------------------
-- 09.1 All-user behavior summary
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 user in the valid analytical-session layer

CREATE MATERIALIZED VIEW
    portofolio_2.mv_user_behavior_summary AS

WITH session_behavior AS (
    SELECT
        user_id,

        COUNT(*) AS analytical_sessions,

        MIN(session_start_utc)
            AS first_seen_utc,

        MAX(session_end_utc)
            AS last_seen_utc,

        COUNT(*) FILTER (
            WHERE has_any_view
        ) AS sessions_with_view,

        COUNT(*) FILTER (
            WHERE has_any_cart
        ) AS sessions_with_cart,

        COUNT(*) FILTER (
            WHERE has_any_remove
        ) AS sessions_with_remove,

        COUNT(*) FILTER (
            WHERE has_any_purchase
        ) AS sessions_with_purchase

    FROM portofolio_2.mv_session_funnel

    GROUP BY user_id
),

event_behavior AS (
    SELECT
        user_id,

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

        COUNT(
            DISTINCT event_time_utc::date
        ) AS active_days,

        COUNT(
            DISTINCT DATE_TRUNC(
                'month',
                event_time_utc
            )
        ) AS active_months,

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

    GROUP BY user_id
)

SELECT
    s.user_id,

    s.first_seen_utc,
    s.last_seen_utc,

    EXTRACT(
        EPOCH FROM (
            s.last_seen_utc
            - s.first_seen_utc
        )
    ) / 86400.0
        AS observed_activity_span_days,

    s.analytical_sessions,

    s.sessions_with_view,
    s.sessions_with_cart,
    s.sessions_with_remove,
    s.sessions_with_purchase,

    e.total_events,
    e.view_events,
    e.cart_events,
    e.remove_events,
    e.purchase_events,

    e.active_days,
    e.active_months,

    e.distinct_products_interacted,
    e.distinct_products_viewed,
    e.distinct_products_carted,
    e.distinct_products_purchased,

    COALESCE(
        p.observed_purchase_value,
        0
    ) AS observed_purchase_value,

    CASE
        WHEN s.sessions_with_purchase > 0
            THEN TRUE
        ELSE FALSE
    END AS is_buyer,

    CASE
        WHEN s.sessions_with_purchase > 0
            THEN 'Buyer'

        WHEN s.sessions_with_cart > 0
          OR s.sessions_with_remove > 0
            THEN 'Cart Interaction — No Purchase'

        WHEN s.sessions_with_view > 0
            THEN 'View Only — No Purchase'

        ELSE 'Other'
    END AS behavior_segment

FROM session_behavior s

JOIN event_behavior e
    ON s.user_id = e.user_id

LEFT JOIN portofolio_2.mv_customer_purchase_summary p
    ON s.user_id = p.user_id;


CREATE UNIQUE INDEX idx_user_behavior_user
ON portofolio_2.mv_user_behavior_summary (
    user_id
);

CREATE INDEX idx_user_behavior_segment
ON portofolio_2.mv_user_behavior_summary (
    behavior_segment
);

ANALYZE portofolio_2.mv_user_behavior_summary;


-- ---------------------------------------------------------
-- 09.2 User-model reconciliation
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS total_users,

    COUNT(DISTINCT user_id)
        AS unique_users,

    COUNT(*) FILTER (
        WHERE is_buyer
    ) AS buyers,

    COUNT(*) FILTER (
        WHERE NOT is_buyer
    ) AS non_buyers,

    SUM(purchase_events)
        AS total_purchase_events,

    ROUND(
        SUM(observed_purchase_value),
        2
    ) AS total_observed_purchase_value

FROM portofolio_2.mv_user_behavior_summary;

-- Observed:
-- total_users                   = 1,638,714
-- unique_users                  = 1,638,714
-- buyers                        =   110,500
-- non_buyers                    = 1,528,214
-- total_purchase_events         = 1,286,898
-- total_observed_purchase_value = 6,351,305.66


-- ---------------------------------------------------------
-- 09.3 Behavioral segmentation
-- ---------------------------------------------------------

SELECT
    behavior_segment,

    COUNT(*) AS users,

    ROUND(
        100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER (),
        2
    ) AS user_share_pct,

    ROUND(
        AVG(analytical_sessions),
        2
    ) AS avg_sessions,

    ROUND(
        AVG(active_days),
        2
    ) AS avg_active_days,

    ROUND(
        AVG(distinct_products_viewed),
        2
    ) AS avg_products_viewed,

    ROUND(
        AVG(distinct_products_carted),
        2
    ) AS avg_products_carted

FROM portofolio_2.mv_user_behavior_summary

GROUP BY behavior_segment

ORDER BY users DESC;

-- Observed:
--
-- View Only — No Purchase
-- users = 1,237,210 (75.50%)
--
-- Cart Interaction — No Purchase
-- users =   291,004 (17.76%)
--
-- Buyer
-- users =   110,500 (6.74%)


-- ---------------------------------------------------------
-- 09.4 Behavioral distribution
-- ---------------------------------------------------------
-- Medians and P75 are preferred over averages because
-- behavioral activity is strongly right-skewed.

SELECT
    behavior_segment,
    COUNT(*) AS users,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY analytical_sessions
        )::numeric,
        2
    ) AS median_sessions,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY analytical_sessions
        )::numeric,
        2
    ) AS p75_sessions,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY active_days
        )::numeric,
        2
    ) AS median_active_days,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY active_days
        )::numeric,
        2
    ) AS p75_active_days,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY total_events
        )::numeric,
        2
    ) AS median_total_events,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY total_events
        )::numeric,
        2
    ) AS p75_total_events,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY distinct_products_viewed
        )::numeric,
        2
    ) AS median_products_viewed,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY distinct_products_viewed
        )::numeric,
        2
    ) AS p75_products_viewed,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY distinct_products_carted
        )::numeric,
        2
    ) AS median_products_carted,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY distinct_products_carted
        )::numeric,
        2
    ) AS p75_products_carted

FROM portofolio_2.mv_user_behavior_summary

GROUP BY behavior_segment

ORDER BY users DESC;

-- Key observed medians:
--
-- View Only:
-- sessions = 1
-- active days = 1
-- events = 1
-- products viewed = 1
--
-- Cart Interaction — No Purchase:
-- sessions = 1
-- active days = 1
-- events = 6
-- products viewed = 2
-- products carted = 2
--
-- Buyer:
-- sessions = 5
-- active days = 3
-- events = 43
-- products viewed = 10
-- products carted = 10


-- ---------------------------------------------------------
-- 09.5 Behavioral persistence
-- ---------------------------------------------------------

SELECT
    behavior_segment,
    COUNT(*) AS users,

    COUNT(*) FILTER (
        WHERE analytical_sessions >= 2
    ) AS multi_session_users,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE analytical_sessions >= 2
        )
        / COUNT(*),
        2
    ) AS multi_session_share,

    COUNT(*) FILTER (
        WHERE active_days >= 2
    ) AS multi_day_users,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE active_days >= 2
        )
        / COUNT(*),
        2
    ) AS multi_day_share,

    COUNT(*) FILTER (
        WHERE analytical_sessions >= 5
    ) AS users_5plus_sessions,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE analytical_sessions >= 5
        )
        / COUNT(*),
        2
    ) AS users_5plus_sessions_share

FROM portofolio_2.mv_user_behavior_summary

GROUP BY behavior_segment

ORDER BY users DESC;

-- Observed multi-session share:
-- View Only                  = 27.60%
-- Cart Interaction           = 48.05%
-- Buyer                      = 82.30%
--
-- Observed 5+ session share:
-- View Only                  =  4.24%
-- Cart Interaction           = 18.58%
-- Buyer                      = 52.64%


-- =========================================================
-- FIRST OBSERVED PURCHASE JOURNEY
-- =========================================================


-- ---------------------------------------------------------
-- 09.6 Buyer first-observed-purchase journey
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 observed buyer
--
-- "First purchase" here means first purchase observed within
-- the dataset window, NOT necessarily first-ever purchase.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_buyer_first_purchase_journey AS

WITH session_order AS (
    SELECT
        user_id,
        analytical_session_id,
        session_start_utc,
        session_end_utc,

        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY
                session_start_utc,
                analytical_session_id
        ) AS session_number

    FROM portofolio_2.mv_analytical_session_summary
),

purchase_sessions AS (
    SELECT
        user_id,
        analytical_session_id,

        MIN(event_time_utc)
            AS first_purchase_in_session_utc

    FROM portofolio_2.mv_events_sessionized

    WHERE event_type = 'purchase'

    GROUP BY
        user_id,
        analytical_session_id
),

first_purchase AS (
    SELECT DISTINCT ON (user_id)
        user_id,

        analytical_session_id
            AS first_purchase_session_id,

        first_purchase_in_session_utc
            AS first_purchase_utc

    FROM purchase_sessions

    ORDER BY
        user_id,
        first_purchase_in_session_utc,
        analytical_session_id
)

SELECT
    fp.user_id,

    ub.first_seen_utc,
    fp.first_purchase_utc,
    fp.first_purchase_session_id,

    so.session_number
        AS first_purchase_session_number,

    so.session_number - 1
        AS sessions_before_first_purchase,

    EXTRACT(
        EPOCH FROM (
            fp.first_purchase_utc
            - ub.first_seen_utc
        )
    ) / 3600.0
        AS hours_to_first_observed_purchase,

    EXTRACT(
        EPOCH FROM (
            fp.first_purchase_utc
            - ub.first_seen_utc
        )
    ) / 86400.0
        AS days_to_first_observed_purchase

FROM first_purchase fp

JOIN session_order so
    ON fp.user_id = so.user_id
   AND fp.first_purchase_session_id
       = so.analytical_session_id

JOIN portofolio_2.mv_user_behavior_summary ub
    ON fp.user_id = ub.user_id;


CREATE UNIQUE INDEX idx_buyer_first_purchase_user
ON portofolio_2.mv_buyer_first_purchase_journey (
    user_id
);

ANALYZE portofolio_2.mv_buyer_first_purchase_journey;


-- ---------------------------------------------------------
-- 09.7 First-purchase-model validation
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS buyers,

    COUNT(DISTINCT user_id)
        AS unique_buyers,

    MIN(first_purchase_session_number)
        AS min_purchase_session_number,

    MIN(hours_to_first_observed_purchase)
        AS min_hours_to_purchase

FROM portofolio_2.mv_buyer_first_purchase_journey;

-- Observed:
-- buyers                      = 110,500
-- unique_buyers               = 110,500
-- min_purchase_session_number = 1
-- min_hours_to_purchase       = 0


-- ---------------------------------------------------------
-- 09.8 Session position of first observed purchase
-- ---------------------------------------------------------

SELECT
    CASE
        WHEN first_purchase_session_number = 1
            THEN '1 — First Session'

        WHEN first_purchase_session_number = 2
            THEN '2 — Second Session'

        WHEN first_purchase_session_number = 3
            THEN '3 — Third Session'

        WHEN first_purchase_session_number BETWEEN 4 AND 5
            THEN '4–5 Sessions'

        WHEN first_purchase_session_number BETWEEN 6 AND 10
            THEN '6–10 Sessions'

        ELSE '11+ Sessions'
    END AS purchase_session_bucket,

    COUNT(*) AS buyers,

    ROUND(
        100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER (),
        2
    ) AS buyer_share_pct

FROM portofolio_2.mv_buyer_first_purchase_journey

GROUP BY 1

ORDER BY
    MIN(first_purchase_session_number);

-- Observed:
-- First Session   = 30.67%
-- Second Session  = 17.87%
-- Third Session   = 11.18%
-- 4–5 Sessions    = 13.19%
-- 6–10 Sessions   = 13.56%
-- 11+ Sessions    = 13.52%


-- ---------------------------------------------------------
-- 09.9 Time to first observed purchase
-- ---------------------------------------------------------

SELECT
    ROUND(
        PERCENTILE_CONT(0.25)
        WITHIN GROUP (
            ORDER BY hours_to_first_observed_purchase
        )::numeric,
        2
    ) AS p25_hours_to_purchase,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY hours_to_first_observed_purchase
        )::numeric,
        2
    ) AS median_hours_to_purchase,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY hours_to_first_observed_purchase
        )::numeric,
        2
    ) AS p75_hours_to_purchase,

    ROUND(
        PERCENTILE_CONT(0.90)
        WITHIN GROUP (
            ORDER BY hours_to_first_observed_purchase
        )::numeric,
        2
    ) AS p90_hours_to_purchase,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE hours_to_first_observed_purchase < 1
        ) / COUNT(*),
        2
    ) AS purchase_within_1_hour_pct,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE hours_to_first_observed_purchase < 24
        ) / COUNT(*),
        2
    ) AS purchase_within_24_hours_pct,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE days_to_first_observed_purchase < 7
        ) / COUNT(*),
        2
    ) AS purchase_within_7_days_pct

FROM portofolio_2.mv_buyer_first_purchase_journey;

-- Observed:
-- P25    =    0.40 hours
-- Median =    5.39 hours
-- P75    =  243.11 hours
-- P90    = 1008.58 hours
--
-- Within 1 hour  = 38.26%
-- Within 24 hrs  = 57.49%
-- Within 7 days  = 71.54%


-- =========================================================
-- PRE-PURCHASE BEHAVIOR
-- =========================================================


-- ---------------------------------------------------------
-- 09.10 Buyer pre-purchase behavior
-- ---------------------------------------------------------
-- Only events strictly before the first purchase timestamp
-- are included.
--
-- Events at the exact same timestamp as first purchase are
-- excluded because intrasecond ordering is unavailable.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_buyer_prepurchase_behavior AS

WITH pre_purchase AS (
    SELECT
        j.user_id,

        COUNT(e.event_type)
            AS pre_purchase_events,

        COUNT(e.event_type) FILTER (
            WHERE e.event_type = 'view'
        ) AS pre_purchase_views,

        COUNT(e.event_type) FILTER (
            WHERE e.event_type = 'cart'
        ) AS pre_purchase_carts,

        COUNT(e.event_type) FILTER (
            WHERE e.event_type = 'remove_from_cart'
        ) AS pre_purchase_removes,

        COUNT(DISTINCT e.analytical_session_id)
            AS sessions_with_activity_before_purchase,

        COUNT(DISTINCT e.product_id) FILTER (
            WHERE e.event_type = 'view'
        ) AS products_viewed_before_purchase,

        COUNT(DISTINCT e.product_id) FILTER (
            WHERE e.event_type = 'cart'
        ) AS products_carted_before_purchase

    FROM portofolio_2.mv_buyer_first_purchase_journey j

    LEFT JOIN portofolio_2.mv_events_sessionized e
        ON j.user_id = e.user_id
       AND e.event_time_utc < j.first_purchase_utc

    GROUP BY j.user_id
)

SELECT
    j.user_id,

    j.first_purchase_utc,
    j.first_purchase_session_number,
    j.sessions_before_first_purchase,
    j.hours_to_first_observed_purchase,

    p.pre_purchase_events,
    p.pre_purchase_views,
    p.pre_purchase_carts,
    p.pre_purchase_removes,

    p.sessions_with_activity_before_purchase,
    p.products_viewed_before_purchase,
    p.products_carted_before_purchase,

    p.pre_purchase_views > 0
        AS had_prior_view,

    p.pre_purchase_carts > 0
        AS had_prior_cart,

    p.pre_purchase_removes > 0
        AS had_prior_remove

FROM portofolio_2.mv_buyer_first_purchase_journey j

JOIN pre_purchase p
    ON j.user_id = p.user_id;


CREATE UNIQUE INDEX idx_buyer_prepurchase_user
ON portofolio_2.mv_buyer_prepurchase_behavior (
    user_id
);

ANALYZE portofolio_2.mv_buyer_prepurchase_behavior;


-- ---------------------------------------------------------
-- 09.11 Pre-purchase behavioral signals
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS buyers,

    COUNT(DISTINCT user_id)
        AS unique_buyers,

    COUNT(*) FILTER (
        WHERE pre_purchase_events = 0
    ) AS buyers_no_prior_event,

    COUNT(*) FILTER (
        WHERE had_prior_view
    ) AS buyers_with_prior_view,

    COUNT(*) FILTER (
        WHERE had_prior_cart
    ) AS buyers_with_prior_cart,

    COUNT(*) FILTER (
        WHERE had_prior_remove
    ) AS buyers_with_prior_remove,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE had_prior_view
        ) / COUNT(*),
        2
    ) AS prior_view_share,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE had_prior_cart
        ) / COUNT(*),
        2
    ) AS prior_cart_share,

    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE had_prior_remove
        ) / COUNT(*),
        2
    ) AS prior_remove_share

FROM portofolio_2.mv_buyer_prepurchase_behavior;

-- Observed:
-- buyers                 = 110,500
-- buyers_no_prior_event  =     598
-- prior view share       = 92.51%
-- prior cart share       = 98.74%
-- prior remove share     = 75.99%


-- ---------------------------------------------------------
-- 09.12 Pre-purchase intensity
-- ---------------------------------------------------------

SELECT
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY pre_purchase_events
        )::numeric,
        2
    ) AS median_pre_purchase_events,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY pre_purchase_events
        )::numeric,
        2
    ) AS p75_pre_purchase_events,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY products_viewed_before_purchase
        )::numeric,
        2
    ) AS median_products_viewed_before_purchase,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY products_viewed_before_purchase
        )::numeric,
        2
    ) AS p75_products_viewed_before_purchase,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY products_carted_before_purchase
        )::numeric,
        2
    ) AS median_products_carted_before_purchase,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY products_carted_before_purchase
        )::numeric,
        2
    ) AS p75_products_carted_before_purchase

FROM portofolio_2.mv_buyer_prepurchase_behavior;

-- Observed:
-- median pre-purchase events          = 25
-- P75 pre-purchase events             = 56
-- median products viewed before buy   = 6
-- P75 products viewed                 = 16
-- median products carted before buy   = 7
-- P75 products carted                 = 16


-- =========================================================
-- METHODOLOGICAL NOTES
-- =========================================================
--
-- 1. Buyer behavior is descriptive association, not causal
--    evidence that additional sessions cause purchase.
--
-- 2. Full buyer behavior contains activity both before and
--    after purchase; pre-purchase analysis is therefore
--    reported separately.
--
-- 3. First observed purchase may not be the customer's
--    first-ever purchase because activity before October
--    2019 is unavailable.
--
-- 4. A cart event may exist without a prior recorded view,
--    so product counts carted can exceed products viewed.
--
-- =========================================================
