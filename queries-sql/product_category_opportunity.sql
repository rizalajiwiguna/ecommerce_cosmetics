--1 Same-product session funnel
CREATE MATERIALIZED VIEW portofolio_2.mv_session_product_funnel AS
WITH timestamp_product_events AS (
    SELECT
        analytical_session_id,
        user_id,
        product_id,
        event_time_utc,
        BOOL_OR(event_type = 'view') AS has_view_at_ts,
        BOOL_OR(event_type = 'cart') AS has_cart_at_ts,
        BOOL_OR(event_type = 'remove_from_cart') AS has_remove_at_ts,
        BOOL_OR(event_type = 'purchase') AS has_purchase_at_ts
    FROM portofolio_2.mv_events_sessionized
    GROUP BY
        analytical_session_id,
        user_id,
        product_id,
        event_time_utc
),
after_view AS (
    SELECT
        *,
        BOOL_OR(has_view_at_ts) OVER (
            PARTITION BY
                analytical_session_id,
                product_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS seen_product_view
    FROM timestamp_product_events
),
after_cart AS (
    SELECT
        *,
        BOOL_OR(
            has_cart_at_ts AND seen_product_view
        ) OVER (
            PARTITION BY
                analytical_session_id,
                product_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS seen_product_cart_after_view
    FROM after_view
)
SELECT
    analytical_session_id,
    user_id,
    product_id,
    MIN(event_time_utc) FILTER (
        WHERE has_view_at_ts) AS first_product_view_utc,
    MIN(event_time_utc) FILTER (
        WHERE has_cart_at_ts
            AND seen_product_view) AS first_product_cart_after_view_utc,
    MIN(event_time_utc) FILTER (
        WHERE has_purchase_at_ts
            AND seen_product_cart_after_view) AS first_product_purchase_after_cart_utc,
    BOOL_OR(has_view_at_ts) AS has_product_view,
    BOOL_OR(
        has_cart_at_ts AND seen_product_view) AS has_product_cart_after_view,
    BOOL_OR(
        has_purchase_at_ts AND seen_product_cart_after_view) AS has_product_purchase_after_cart
FROM after_cart
GROUP BY
    analytical_session_id,
    user_id,
    product_id;

CREATE INDEX idx_session_product_funnel_product
    ON portofolio_2.mv_session_product_funnel (product_id);

CREATE INDEX idx_session_product_funnel_session
    ON portofolio_2.mv_session_product_funnel (analytical_session_id);

ANALYZE portofolio_2.mv_session_product_funnel;

--2 Product-funnel validation
SELECT
    COUNT(*) AS session_product_rows,
    COUNT(DISTINCT product_id) AS unique_products,
    COUNT(*) FILTER (
        WHERE has_product_view) AS viewed_session_products,
    COUNT(*) FILTER (
        WHERE has_product_cart_after_view) AS carted_session_products,
    COUNT(*) FILTER (
        WHERE has_product_purchase_after_cart) AS purchased_session_products
FROM portofolio_2.mv_session_product_funnel;
--Observed:
--session_product_rows       = 14,228,261
--unique_products            = 54,570
--viewed_session_products    = 8,494,511
--carted_session_products    = 913,989
--purchased_session_products = 126,118

--3 Product funnel performance
CREATE MATERIALIZED VIEW portofolio_2.mv_product_funnel_performance AS
WITH product_funnel AS (
    SELECT
        product_id,
        COUNT(*) FILTER (
            WHERE has_product_view) AS view_sessions,
        COUNT(*) FILTER (
            WHERE has_product_cart_after_view) AS cart_after_view_sessions,
        COUNT(*) FILTER (
            WHERE has_product_purchase_after_cart) AS purchase_after_cart_sessions
    FROM portofolio_2.mv_session_product_funnel
    GROUP BY product_id
),
purchase_value AS (
    SELECT
        product_id,
        COUNT(*) FILTER (
            WHERE event_type = 'purchase') AS purchase_events,
        COUNT(*) FILTER (
            WHERE is_valid_monetary_purchase) AS valid_monetary_purchase_events,
        SUM(observed_purchase_value) AS observed_purchase_value
    FROM portofolio_2.mv_events_sessionized
    GROUP BY product_id
)
SELECT
    f.product_id,
    f.view_sessions,
    f.cart_after_view_sessions,
    f.purchase_after_cart_sessions,
    ROUND(100.0 * f.cart_after_view_sessions / NULLIF(f.view_sessions, 0),2) AS view_to_cart_rate,
    ROUND(100.0 * f.purchase_after_cart_sessions/ NULLIF(f.cart_after_view_sessions, 0),2) AS cart_to_purchase_rate,
    ROUND(100.0 * f.purchase_after_cart_sessions/ NULLIF(f.view_sessions, 0),2) AS view_to_purchase_rate,
    COALESCE(p.purchase_events, 0) AS purchase_events,
    COALESCE(p.valid_monetary_purchase_events, 0) AS valid_monetary_purchase_events,
    COALESCE(p.observed_purchase_value, 0) AS observed_purchase_value
FROM product_funnel f
LEFT JOIN purchase_value p
    ON f.product_id = p.product_id;

CREATE UNIQUE INDEX idx_product_funnel_performance_product
    ON portofolio_2.mv_product_funnel_performance (product_id);

ANALYZE portofolio_2.mv_product_funnel_performance;

--4 Product-model reconciliation
SELECT
    COUNT(*) AS total_products,
    SUM(view_sessions) AS total_view_session_products,
    SUM(cart_after_view_sessions) AS total_cart_session_products,
    SUM(purchase_after_cart_sessions) AS total_purchase_session_products,
    SUM(purchase_events) AS total_purchase_events,
    SUM(valid_monetary_purchase_events) AS valid_monetary_purchase_events,
    ROUND(SUM(observed_purchase_value),2) AS total_observed_purchase_value
FROM portofolio_2.mv_product_funnel_performance;
--total_products                  = 54,570
--total_view_session_products     = 8,494,511
--total_cart_session_products     = 913,989
--total_purchase_session_products = 126,118
--total_purchase_events           = 1,286,898
--valid_monetary_purchase_events  = 1,286,771
--total_observed_purchase_value   = 6,351,305.66

--5 Product traffic distribution
SELECT
    ROUND(
        PERCENTILE_CONT(0.25) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS p25_view_sessions,
    ROUND(
        PERCENTILE_CONT(0.50) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS median_view_sessions,
    ROUND(
        PERCENTILE_CONT(0.75) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS p75_view_sessions,
    ROUND(
        PERCENTILE_CONT(0.90) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS p90_view_sessions,
    ROUND(
        PERCENTILE_CONT(0.95) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS p95_view_sessions,
    MAX(view_sessions) AS max_view_sessions
FROM portofolio_2.mv_product_funnel_performance
WHERE view_sessions > 0;
--p25_view_sessions    = 13
--median_view_sessions = 45
--p75_view_sessions    = 123
--p90_view_sessions    = 321
--p95_view_sessions    = 583
--max_view_sessions    = 79,712

--6 Product eligibility rule
SELECT
    COUNT(*) FILTER(WHERE view_sessions < 10) AS products_under_10_views,
    COUNT(*) FILTER(WHERE view_sessions BETWEEN 10 AND 49) AS products_10_49_views,
    COUNT(*) FILTER(WHERE view_sessions BETWEEN 50 AND 99) AS products_50_99_views,
    COUNT(*) FILTER(WHERE view_sessions >= 100) AS products_100_plus_views,
    COUNT(*) FILTER(WHERE view_sessions >= 500) AS products_500_plus_views,
    COUNT(*) FILTER(WHERE view_sessions >= 1000) AS products_1000_plus_views
FROM portofolio_2.mv_product_funnel_performance;
--products_under_10_views  = 11,883
--products_10_49_views     = 17,241
--products_50_99_views     = 9,545
--products_100_plus_views  = 15,901
--products_500_plus_views  = 3,300
--products_1000_plus_views = 1,353

--7 Eligible-product benchmark
SELECT
    COUNT(*) AS eligible_products,
    ROUND(PERCENTILE_CONT(0.50) 
        WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS median_eligible_views,
    SUM(view_sessions) AS eligible_view_sessions,
    SUM(cart_after_view_sessions) AS eligible_cart_sessions,
    SUM(purchase_after_cart_sessions) AS eligible_purchase_sessions,
    ROUND(100.0 * SUM(cart_after_view_sessions)/ NULLIF(SUM(view_sessions), 0),2) AS weighted_view_to_cart_rate,
    ROUND(100.0 * SUM(purchase_after_cart_sessions)/ NULLIF(SUM(cart_after_view_sessions), 0),2) AS weighted_cart_to_purchase_rate,
    ROUND(100.0 * SUM(purchase_after_cart_sessions)/ NULLIF(SUM(view_sessions), 0),2) AS weighted_view_to_purchase_rate
FROM portofolio_2.mv_product_funnel_performance
WHERE view_sessions >= 100;
--eligible_products              = 15,901
--median_eligible_views          = 221
--eligible_view_sessions         = 7,307,299
--eligible_cart_sessions         = 784,991
--eligible_purchase_sessions     = 111,326
--weighted_view_to_cart_rate     = 10.74
--weighted_cart_to_purchase_rate = 14.18
--weighted_view_to_purchase_rate = 1.52

--8 Product Opportunity Matrix
CREATE MATERIALIZED VIEW portofolio_2.mv_product_opportunity_matrix AS
WITH eligible AS (
    SELECT
        *
    FROM portofolio_2.mv_product_funnel_performance
    WHERE view_sessions >= 100
),
benchmarks AS (
    SELECT
        PERCENTILE_CONT(0.50) WITHIN GROUP (
            ORDER BY view_sessions) AS traffic_threshold,
        SUM(purchase_after_cart_sessions)::numeric
            / NULLIF(SUM(view_sessions), 0) AS conversion_benchmark,
        SUM(cart_after_view_sessions)::numeric
            / NULLIF(SUM(view_sessions), 0) AS view_to_cart_benchmark,
        SUM(purchase_after_cart_sessions)::numeric
            / NULLIF(SUM(cart_after_view_sessions), 0) AS cart_to_purchase_benchmark
    FROM eligible
),
scored AS (
    SELECT
        e.*,
        b.traffic_threshold,
        b.conversion_benchmark,
        b.view_to_cart_benchmark,
        b.cart_to_purchase_benchmark,
        e.purchase_after_cart_sessions::numeric
            / NULLIF(e.view_sessions, 0) AS product_conversion_rate_raw,
        e.cart_after_view_sessions::numeric
            / NULLIF(e.view_sessions, 0) AS product_view_to_cart_raw,
        e.purchase_after_cart_sessions::numeric
            / NULLIF(e.cart_after_view_sessions, 0) AS product_cart_to_purchase_raw
    FROM eligible e
    CROSS JOIN benchmarks b
)
SELECT
    product_id,
    view_sessions,
    cart_after_view_sessions,
    purchase_after_cart_sessions,
    view_to_cart_rate,
    cart_to_purchase_rate,
    view_to_purchase_rate,
    purchase_events,
    valid_monetary_purchase_events,
    observed_purchase_value,
    ROUND(traffic_threshold::numeric, 0) AS traffic_threshold,
    ROUND(100 * conversion_benchmark, 2) AS conversion_benchmark_pct,
    ROUND(100 * view_to_cart_benchmark, 2) AS view_to_cart_benchmark_pct,
    ROUND(100 * cart_to_purchase_benchmark, 2)
        AS cart_to_purchase_benchmark_pct,
    CASE
        WHEN view_sessions >= traffic_threshold
            AND product_conversion_rate_raw >= conversion_benchmark
            THEN 'Protect & Scale'
        WHEN view_sessions >= traffic_threshold
            AND product_conversion_rate_raw < conversion_benchmark
            THEN 'Fix First'
        WHEN view_sessions < traffic_threshold
            AND product_conversion_rate_raw >= conversion_benchmark
            THEN 'Hidden Winner'
        ELSE 'Deprioritize'
    END AS opportunity_segment,
    ROUND(
        (view_sessions * conversion_benchmark)::numeric,2) AS expected_purchase_sessions_at_benchmark,
    ROUND(
        GREATEST(view_sessions * conversion_benchmark - purchase_after_cart_sessions,0)::numeric,2) AS conversion_gap_sessions,
    ROUND(100 * product_view_to_cart_raw/ NULLIF(view_to_cart_benchmark, 0),2) AS view_to_cart_index,
    ROUND(100 * product_cart_to_purchase_raw/ NULLIF(cart_to_purchase_benchmark, 0),2) AS cart_to_purchase_index
FROM scored;

CREATE UNIQUE INDEX idx_product_opportunity_product
    ON portofolio_2.mv_product_opportunity_matrix (product_id);

CREATE INDEX idx_product_opportunity_segment
    ON portofolio_2.mv_product_opportunity_matrix (opportunity_segment);

ANALYZE portofolio_2.mv_product_opportunity_matrix;

--9 Opportunity-segment validation
SELECT
    opportunity_segment,
    COUNT(*) AS products,
    SUM(view_sessions) AS view_sessions,
    SUM(purchase_after_cart_sessions) AS purchase_sessions,
    ROUND(100.0 * SUM(purchase_after_cart_sessions)/ NULLIF(SUM(view_sessions), 0),2) AS weighted_conversion_rate,
    ROUND(SUM(conversion_gap_sessions),2) AS total_conversion_gap_sessions
FROM portofolio_2.mv_product_opportunity_matrix
GROUP BY opportunity_segment
ORDER BY products DESC;
/*
opportunity_segment         = Deprioritize
-products                    = 4,846
-view_sessions               = 716,625
-purchase_sessions           = 4,324
-weighted_conversion_rate    = 0.60
-total_conversion_gap_sessions = 6,593.13

opportunity_segment         = Fix First
-products                    = 4,499
-view_sessions               = 3,621,423
-purchase_sessions           = 30,603
-weighted_conversion_rate    = 0.85
-total_conversion_gap_sessions = 24,568.63

opportunity_segment         = Protect & Scale
-products                    = 3,476
-view_sessions               = 2,514,908
-purchase_sessions           = 64,045
-weighted_conversion_rate    = 2.55

opportunity_segment         = Hidden Winner
-products                    = 3,080
-view_sessions               = 454,343
-purchase_sessions           = 12,354
-weighted_conversion_rate    = 2.72
*/

--10 Fix First bottleneck diagnosis
WITH diagnosed AS (
    SELECT
        *,
        CASE
            WHEN cart_after_view_sessions = 0
                THEN 'View → Cart'
            WHEN view_to_cart_index < 100
                AND cart_to_purchase_index >= 100
                THEN 'View → Cart'
            WHEN view_to_cart_index >= 100
                AND cart_to_purchase_index < 100
                THEN 'Cart → Purchase'
            WHEN view_to_cart_index < 100
                AND cart_to_purchase_index < 100
                AND view_to_cart_index <= cart_to_purchase_index
                THEN 'Both — View → Cart Weaker'
            WHEN view_to_cart_index < 100
                AND cart_to_purchase_index < 100
                AND cart_to_purchase_index < view_to_cart_index
                THEN 'Both — Cart → Purchase Weaker'
            ELSE 'Review'
        END AS primary_bottleneck
    FROM portofolio_2.mv_product_opportunity_matrix
    WHERE opportunity_segment = 'Fix First'
)
SELECT
    primary_bottleneck,
    COUNT(*) AS products,
    SUM(view_sessions) AS view_sessions,
    SUM(purchase_after_cart_sessions) AS purchase_sessions,
    ROUND(100.0 * SUM(purchase_after_cart_sessions)/ NULLIF(SUM(view_sessions), 0),2) AS weighted_conversion_rate,
    ROUND(SUM(conversion_gap_sessions),2) AS conversion_gap_sessions
FROM diagnosed
GROUP BY primary_bottleneck
ORDER BY conversion_gap_sessions DESC;
/*
primary_bottleneck       = Both — View → Cart Weaker
-products                 = 895
-view_sessions            = 923,769
-purchase_sessions        = 5,365
-weighted_conversion_rate = 0.58
-conversion_gap_sessions  = 8,708.53

primary_bottleneck       = Both — Cart → Purchase Weaker
-products                 = 1,404
-view_sessions            = 921,233
-purchase_sessions        = 6,585
-weighted_conversion_rate = 0.71
-conversion_gap_sessions  = 7,449.73

primary_bottleneck       = View → Cart
-products                 = 1,032
-view_sessions            = 1,090,539
-purchase_sessions        = 10,834
-weighted_conversion_rate = 0.99
-conversion_gap_sessions  = 5,780.04

primary_bottleneck       = Cart → Purchase
-products                 = 1,168
-view_sessions            = 685,882
-purchase_sessions        = 7,819
-weighted_conversion_rate = 1.14
-conversion_gap_sessions  = 2,630.33

Review                   = 0
*/

--11 Top Fix First opportunities
WITH diagnosed AS (
    SELECT
        *,
        CASE
            WHEN cart_after_view_sessions = 0
                THEN 'View → Cart'
            WHEN view_to_cart_index < 100
                AND cart_to_purchase_index >= 100
                THEN 'View → Cart'
            WHEN view_to_cart_index >= 100
                AND cart_to_purchase_index < 100
                THEN 'Cart → Purchase'
            WHEN view_to_cart_index < 100
                AND cart_to_purchase_index < 100
                AND view_to_cart_index <= cart_to_purchase_index
                THEN 'Both — View → Cart Weaker'
            WHEN view_to_cart_index < 100
                AND cart_to_purchase_index < 100
                AND cart_to_purchase_index < view_to_cart_index
                THEN 'Both — Cart → Purchase Weaker'
            ELSE 'Review'
        END AS primary_bottleneck
    FROM portofolio_2.mv_product_opportunity_matrix
    WHERE opportunity_segment = 'Fix First'
)
SELECT
    product_id,
    view_sessions,
    purchase_after_cart_sessions,
    view_to_cart_rate,
    cart_to_purchase_rate,
    view_to_purchase_rate,
    view_to_cart_index,
    cart_to_purchase_index,
    primary_bottleneck,
    observed_purchase_value,
    conversion_gap_sessions
FROM diagnosed
ORDER BY
    conversion_gap_sessions DESC,
    view_sessions DESC
LIMIT 20;

--12 Same-category session funnel
CREATE MATERIALIZED VIEW portofolio_2.mv_session_category_funnel AS
WITH timestamp_category_events AS (
    SELECT
        analytical_session_id,
        user_id,
        category_id,
        event_time_utc,
        BOOL_OR(event_type = 'view') AS has_view_at_ts,
        BOOL_OR(event_type = 'cart') AS has_cart_at_ts,
        BOOL_OR(event_type = 'purchase') AS has_purchase_at_ts
    FROM portofolio_2.mv_events_sessionized
    GROUP BY
        analytical_session_id,
        user_id,
        category_id,
        event_time_utc
),
after_view AS (
    SELECT
        *,
        BOOL_OR(has_view_at_ts) OVER (
            PARTITION BY
                analytical_session_id,
                category_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS seen_category_view
    FROM timestamp_category_events
),
after_cart AS (
    SELECT
        *,
        BOOL_OR(
            has_cart_at_ts AND seen_category_view
        ) OVER (
            PARTITION BY
                analytical_session_id,
                category_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS seen_category_cart_after_view
    FROM after_view
)
SELECT
    analytical_session_id,
    user_id,
    category_id,
    BOOL_OR(has_view_at_ts) AS has_category_view,
    BOOL_OR(
        has_cart_at_ts AND seen_category_view) AS has_category_cart_after_view,
    BOOL_OR(
        has_purchase_at_ts AND seen_category_cart_after_view) AS has_category_purchase_after_cart
FROM after_cart
GROUP BY
    analytical_session_id,
    user_id,
    category_id;

CREATE INDEX idx_session_category_funnel_category
    ON portofolio_2.mv_session_category_funnel (category_id);

ANALYZE portofolio_2.mv_session_category_funnel;

--13 Category funnel performance
CREATE MATERIALIZED VIEW portofolio_2.mv_category_funnel_performance AS
SELECT
    category_id,
    COUNT(*) FILTER (
        WHERE has_category_view) AS view_sessions,
    COUNT(*) FILTER (
        WHERE has_category_cart_after_view) AS cart_after_view_sessions,
    COUNT(*) FILTER (
        WHERE has_category_purchase_after_cart) AS purchase_after_cart_sessions,
    ROUND(100.0 * COUNT(*) FILTER(WHERE has_category_cart_after_view) / NULLIF(COUNT(*) FILTER (
                WHERE has_category_view),0),2) AS view_to_cart_rate,
    ROUND(100.0 * COUNT(*) FILTER(WHERE has_category_purchase_after_cart) / NULLIF(COUNT(*) FILTER (
                WHERE has_category_cart_after_view),0),2) AS cart_to_purchase_rate,
    ROUND(100.0 * COUNT(*) FILTER (WHERE has_category_purchase_after_cart) / NULLIF(COUNT(*) FILTER (WHERE has_category_view),0),2) AS view_to_purchase_rate
FROM portofolio_2.mv_session_category_funnel
GROUP BY category_id;

CREATE UNIQUE INDEX idx_category_funnel_performance_category
    ON portofolio_2.mv_category_funnel_performance (category_id);

ANALYZE portofolio_2.mv_category_funnel_performance;


-- 08.14 Category traffic distribution
SELECT
    COUNT(*) AS categories,
    ROUND(
        PERCENTILE_CONT(0.25) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS p25_views,
    ROUND(
        PERCENTILE_CONT(0.50) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS median_views,
    ROUND(
        PERCENTILE_CONT(0.75) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS p75_views,
    ROUND(
        PERCENTILE_CONT(0.90) WITHIN GROUP (
            ORDER BY view_sessions)::numeric,0) AS p90_views,
    MAX(view_sessions) AS max_views
FROM portofolio_2.mv_category_funnel_performance;
--categories   = 525
--p25_views    = 671
--median_views = 2,922
--p75_views    = 10,223
--p90_views    = 29,439
--max_views    = 229,293

--15 Category-level weighted benchmark
SELECT
    SUM(view_sessions) AS category_view_sessions,
    SUM(cart_after_view_sessions) AS category_cart_sessions,
    SUM(purchase_after_cart_sessions) AS category_purchase_sessions,
    ROUND(100.0 * SUM(cart_after_view_sessions)/ NULLIF(SUM(view_sessions), 0),2) AS weighted_view_to_cart_rate,
    ROUND(100.0 * SUM(purchase_after_cart_sessions)/ NULLIF(SUM(cart_after_view_sessions), 0),2) AS weighted_cart_to_purchase_rate,
    ROUND(100.0 * SUM(purchase_after_cart_sessions)/ NULLIF(SUM(view_sessions), 0),2) AS weighted_view_to_purchase_rate
FROM portofolio_2.mv_category_funnel_performance;
--weighted_view_to_cart_rate     = 15.53
--weighted_cart_to_purchase_rate = 15.07
--weighted_view_to_purchase_rate = 2.34

--16 High-traffic underperforming category watchlist
WITH benchmark AS (
    SELECT
        PERCENTILE_CONT(0.75) WITHIN GROUP (
            ORDER BY view_sessions) AS high_traffic_threshold,
        SUM(cart_after_view_sessions)::numeric / NULLIF(SUM(view_sessions), 0) AS view_to_cart_benchmark,
        SUM(purchase_after_cart_sessions)::numeric / NULLIF(SUM(cart_after_view_sessions), 0) AS cart_to_purchase_benchmark,
        SUM(purchase_after_cart_sessions)::numeric / NULLIF(SUM(view_sessions), 0) AS conversion_benchmark
    FROM portofolio_2.mv_category_funnel_performance
),
scored AS (
    SELECT
        c.*,
        b.high_traffic_threshold,
        b.view_to_cart_benchmark,
        b.cart_to_purchase_benchmark,
        b.conversion_benchmark,
        c.cart_after_view_sessions::numeric / NULLIF(c.view_sessions, 0) AS view_to_cart_raw,
        c.purchase_after_cart_sessions::numeric / NULLIF(c.cart_after_view_sessions, 0) AS cart_to_purchase_raw,
        c.purchase_after_cart_sessions::numeric / NULLIF(c.view_sessions, 0) AS conversion_raw
    FROM portofolio_2.mv_category_funnel_performance c
    CROSS JOIN benchmark b
)
SELECT
    category_id,
    view_sessions,
    cart_after_view_sessions,
    purchase_after_cart_sessions,
    view_to_cart_rate,
    cart_to_purchase_rate,
    view_to_purchase_rate,
    ROUND(high_traffic_threshold::numeric, 0) AS high_traffic_threshold,
    ROUND(100 * view_to_cart_benchmark, 2) AS view_to_cart_benchmark,
    ROUND(100 * cart_to_purchase_benchmark, 2) AS cart_to_purchase_benchmark,
    ROUND(100 * conversion_benchmark, 2) AS conversion_benchmark,
    ROUND(100 * view_to_cart_raw / NULLIF(view_to_cart_benchmark, 0), 2) AS view_to_cart_index,
    ROUND(100 * cart_to_purchase_raw / NULLIF(cart_to_purchase_benchmark, 0), 2) AS cart_to_purchase_index,
    ROUND(GREATEST(view_sessions * conversion_benchmark - purchase_after_cart_sessions, 0), 2) AS conversion_gap_sessions
FROM scored
WHERE view_sessions >= high_traffic_threshold
    AND conversion_raw < conversion_benchmark
ORDER BY
    conversion_gap_sessions DESC,
    view_sessions DESC
LIMIT 20;
