-- =========================================================
-- BEAUTYCOMMERCE — CUSTOMER JOURNEY, CONVERSION
-- & RETENTION ANALYTICS
-- =========================================================
-- 08. PRODUCT & CATEGORY OPPORTUNITY
-- =========================================================
--
-- Project:
-- BeautyCommerce — Customer Journey, Conversion
-- & Retention Analytics
--
-- Depends on:
-- portofolio_2.mv_events_sessionized
--
-- Produces:
-- portofolio_2.mv_session_product_funnel
-- portofolio_2.mv_product_funnel_performance
-- portofolio_2.mv_product_opportunity_matrix
-- portofolio_2.mv_session_category_funnel
-- portofolio_2.mv_category_funnel_performance
--
-- Analytical timezone:
-- UTC
--
-- Purpose:
-- Identify products with material traffic but below-benchmark
-- conversion performance, distinguish their primary funnel
-- bottleneck, and use category performance as supporting
-- context.
--
-- Product funnel requirement:
-- Progression must occur on the SAME product.
--
-- Example:
--
-- view Product A
-- → cart Product B
-- → purchase Product B
--
-- does NOT count as Product A conversion.
--
-- =========================================================


-- =========================================================
-- PRODUCT OPPORTUNITY ANALYSIS
-- =========================================================


-- ---------------------------------------------------------
-- 08.1 Same-product session funnel
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 analytical_session_id × 1 product_id
--
-- Funnel stages:
-- View
-- → Cart after same-product View
-- → Purchase after same-product qualifying Cart
--
-- Events at the same timestamp are considered eligible for
-- progression because the source data does not contain an
-- intrasecond event-order identifier.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_session_product_funnel AS

WITH timestamp_product_events AS (
    SELECT
        analytical_session_id,
        user_id,
        product_id,
        event_time_utc,

        BOOL_OR(
            event_type = 'view'
        ) AS has_view_at_ts,

        BOOL_OR(
            event_type = 'cart'
        ) AS has_cart_at_ts,

        BOOL_OR(
            event_type = 'remove_from_cart'
        ) AS has_remove_at_ts,

        BOOL_OR(
            event_type = 'purchase'
        ) AS has_purchase_at_ts

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

        BOOL_OR(
            has_view_at_ts
        ) OVER (
            PARTITION BY
                analytical_session_id,
                product_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND CURRENT ROW
        ) AS seen_product_view

    FROM timestamp_product_events
),

after_cart AS (
    SELECT
        *,

        BOOL_OR(
            has_cart_at_ts
            AND seen_product_view
        ) OVER (
            PARTITION BY
                analytical_session_id,
                product_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND CURRENT ROW
        ) AS seen_product_cart_after_view

    FROM after_view
)

SELECT
    analytical_session_id,
    user_id,
    product_id,

    MIN(event_time_utc) FILTER (
        WHERE has_view_at_ts
    ) AS first_product_view_utc,

    MIN(event_time_utc) FILTER (
        WHERE has_cart_at_ts
          AND seen_product_view
    ) AS first_product_cart_after_view_utc,

    MIN(event_time_utc) FILTER (
        WHERE has_purchase_at_ts
          AND seen_product_cart_after_view
    ) AS first_product_purchase_after_cart_utc,

    BOOL_OR(
        has_view_at_ts
    ) AS has_product_view,

    BOOL_OR(
        has_cart_at_ts
        AND seen_product_view
    ) AS has_product_cart_after_view,

    BOOL_OR(
        has_purchase_at_ts
        AND seen_product_cart_after_view
    ) AS has_product_purchase_after_cart

FROM after_cart

GROUP BY
    analytical_session_id,
    user_id,
    product_id;


CREATE INDEX idx_session_product_funnel_product
ON portofolio_2.mv_session_product_funnel (
    product_id
);

CREATE INDEX idx_session_product_funnel_session
ON portofolio_2.mv_session_product_funnel (
    analytical_session_id
);

ANALYZE portofolio_2.mv_session_product_funnel;


-- ---------------------------------------------------------
-- 08.2 Product-funnel validation
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS session_product_rows,

    COUNT(
        DISTINCT product_id
    ) AS unique_products,

    COUNT(*) FILTER (
        WHERE has_product_view
    ) AS viewed_session_products,

    COUNT(*) FILTER (
        WHERE has_product_cart_after_view
    ) AS carted_session_products,

    COUNT(*) FILTER (
        WHERE has_product_purchase_after_cart
    ) AS purchased_session_products

FROM portofolio_2.mv_session_product_funnel;

-- Observed:
-- session_product_rows        = 14,228,261
-- unique_products             =     54,570
-- viewed_session_products     =  8,494,511
-- carted_session_products     =    913,989
-- purchased_session_products  =    126,118


-- ---------------------------------------------------------
-- 08.3 Product funnel performance
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 product_id
--
-- IMPORTANT MONETARY NOTE:
--
-- observed_purchase_value represents ALL positive-price
-- purchase events for each product within valid analytical
-- sessions.
--
-- It is NOT restricted only to purchases that completed the
-- qualified same-product View → Cart → Purchase funnel.
--
-- Therefore:
--
-- purchase_after_cart_sessions
-- = qualified sequential funnel metric
--
-- observed_purchase_value
-- = historical monetary value from all positive-price
--   purchase events for that product
--
-- These metrics serve different analytical purposes.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_product_funnel_performance AS

WITH product_funnel AS (
    SELECT
        product_id,

        COUNT(*) FILTER (
            WHERE has_product_view
        ) AS view_sessions,

        COUNT(*) FILTER (
            WHERE has_product_cart_after_view
        ) AS cart_after_view_sessions,

        COUNT(*) FILTER (
            WHERE has_product_purchase_after_cart
        ) AS purchase_after_cart_sessions

    FROM portofolio_2.mv_session_product_funnel

    GROUP BY product_id
),

purchase_value AS (
    SELECT
        product_id,

        COUNT(*) FILTER (
            WHERE event_type = 'purchase'
        ) AS purchase_events,

        COUNT(*) FILTER (
            WHERE is_valid_monetary_purchase
        ) AS valid_monetary_purchase_events,

        SUM(
            observed_purchase_value
        ) AS observed_purchase_value

    FROM portofolio_2.mv_events_sessionized

    GROUP BY product_id
)

SELECT
    f.product_id,

    f.view_sessions,
    f.cart_after_view_sessions,
    f.purchase_after_cart_sessions,

    ROUND(
        100.0
        * f.cart_after_view_sessions
        / NULLIF(
            f.view_sessions,
            0
        ),
        2
    ) AS view_to_cart_rate,

    ROUND(
        100.0
        * f.purchase_after_cart_sessions
        / NULLIF(
            f.cart_after_view_sessions,
            0
        ),
        2
    ) AS cart_to_purchase_rate,

    ROUND(
        100.0
        * f.purchase_after_cart_sessions
        / NULLIF(
            f.view_sessions,
            0
        ),
        2
    ) AS view_to_purchase_rate,

    COALESCE(
        p.purchase_events,
        0
    ) AS purchase_events,

    COALESCE(
        p.valid_monetary_purchase_events,
        0
    ) AS valid_monetary_purchase_events,

    COALESCE(
        p.observed_purchase_value,
        0
    ) AS observed_purchase_value

FROM product_funnel f

LEFT JOIN purchase_value p
    ON f.product_id = p.product_id;


CREATE UNIQUE INDEX idx_product_funnel_performance_product
ON portofolio_2.mv_product_funnel_performance (
    product_id
);

ANALYZE portofolio_2.mv_product_funnel_performance;


-- ---------------------------------------------------------
-- 08.4 Product-model reconciliation
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS total_products,

    SUM(
        view_sessions
    ) AS total_view_session_products,

    SUM(
        cart_after_view_sessions
    ) AS total_cart_session_products,

    SUM(
        purchase_after_cart_sessions
    ) AS total_purchase_session_products,

    SUM(
        purchase_events
    ) AS total_purchase_events,

    SUM(
        valid_monetary_purchase_events
    ) AS valid_monetary_purchase_events,

    ROUND(
        SUM(
            observed_purchase_value
        ),
        2
    ) AS total_observed_purchase_value

FROM portofolio_2.mv_product_funnel_performance;

-- Observed:
-- total_products                  = 54,570
-- total_view_session_products     = 8,494,511
-- total_cart_session_products     =   913,989
-- total_purchase_session_products =   126,118
-- total_purchase_events           = 1,286,898
-- valid_monetary_purchase_events  = 1,286,771
-- observed_purchase_value         = 6,351,305.66


-- ---------------------------------------------------------
-- 08.5 Product traffic distribution
-- ---------------------------------------------------------

SELECT
    ROUND(
        PERCENTILE_CONT(0.25)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS p25_view_sessions,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS median_view_sessions,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS p75_view_sessions,

    ROUND(
        PERCENTILE_CONT(0.90)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS p90_view_sessions,

    ROUND(
        PERCENTILE_CONT(0.95)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS p95_view_sessions,

    MAX(
        view_sessions
    ) AS max_view_sessions

FROM portofolio_2.mv_product_funnel_performance

WHERE view_sessions > 0;

-- Observed:
-- P25    = 13
-- Median = 45
-- P75    = 123
-- P90    = 321
-- P95    = 583
-- Max    = 79,712


-- ---------------------------------------------------------
-- 08.6 Product eligibility rule
-- ---------------------------------------------------------
--
-- Minimum analytical support:
-- view_sessions >= 100
--
-- This is a project-specific practical threshold used to
-- reduce unstable conversion rankings caused by products
-- with very small denominators.
--
-- It is NOT presented as a universal statistical threshold.

SELECT
    COUNT(*) FILTER (
        WHERE view_sessions < 10
    ) AS products_under_10_views,

    COUNT(*) FILTER (
        WHERE view_sessions BETWEEN 10 AND 49
    ) AS products_10_49_views,

    COUNT(*) FILTER (
        WHERE view_sessions BETWEEN 50 AND 99
    ) AS products_50_99_views,

    COUNT(*) FILTER (
        WHERE view_sessions >= 100
    ) AS products_100_plus_views,

    COUNT(*) FILTER (
        WHERE view_sessions >= 500
    ) AS products_500_plus_views,

    COUNT(*) FILTER (
        WHERE view_sessions >= 1000
    ) AS products_1000_plus_views

FROM portofolio_2.mv_product_funnel_performance;

-- Observed:
-- <10       = 11,883
-- 10–49     = 17,241
-- 50–99     =  9,545
-- >=100     = 15,901
-- >=500     =  3,300
-- >=1000    =  1,353


-- ---------------------------------------------------------
-- 08.7 Eligible-product benchmark
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS eligible_products,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS median_eligible_views,

    SUM(
        view_sessions
    ) AS eligible_view_sessions,

    SUM(
        cart_after_view_sessions
    ) AS eligible_cart_sessions,

    SUM(
        purchase_after_cart_sessions
    ) AS eligible_purchase_sessions,

    ROUND(
        100.0
        * SUM(
            cart_after_view_sessions
        )
        / NULLIF(
            SUM(
                view_sessions
            ),
            0
        ),
        2
    ) AS weighted_view_to_cart_rate,

    ROUND(
        100.0
        * SUM(
            purchase_after_cart_sessions
        )
        / NULLIF(
            SUM(
                cart_after_view_sessions
            ),
            0
        ),
        2
    ) AS weighted_cart_to_purchase_rate,

    ROUND(
        100.0
        * SUM(
            purchase_after_cart_sessions
        )
        / NULLIF(
            SUM(
                view_sessions
            ),
            0
        ),
        2
    ) AS weighted_view_to_purchase_rate

FROM portofolio_2.mv_product_funnel_performance

WHERE view_sessions >= 100;

-- Observed:
-- eligible_products            = 15,901
-- median_eligible_views        = 221
-- eligible_view_sessions       = 7,307,299
-- eligible_cart_sessions       =   784,991
-- eligible_purchase_sessions   =   111,326
-- weighted View → Cart         = 10.74%
-- weighted Cart → Purchase     = 14.18%
-- weighted View → Purchase     =  1.52%


-- ---------------------------------------------------------
-- 08.8 Product Opportunity Matrix
-- ---------------------------------------------------------
--
-- Eligibility:
-- view_sessions >= 100
--
-- Traffic threshold:
-- Median view sessions among eligible products
--
-- Conversion threshold:
-- Weighted View → Purchase rate among eligible products
--
-- Matrix:
--
-- High Traffic + High Conversion
-- → Protect & Scale
--
-- High Traffic + Low Conversion
-- → Fix First
--
-- Low Traffic + High Conversion
-- → Hidden Winner
--
-- Low Traffic + Low Conversion
-- → Deprioritize

CREATE MATERIALIZED VIEW
    portofolio_2.mv_product_opportunity_matrix AS

WITH eligible AS (
    SELECT
        *

    FROM portofolio_2.mv_product_funnel_performance

    WHERE view_sessions >= 100
),

benchmarks AS (
    SELECT
        PERCENTILE_CONT(0.50)
            WITHIN GROUP (
                ORDER BY view_sessions
            ) AS traffic_threshold,

        SUM(
            purchase_after_cart_sessions
        )::numeric
        /
        NULLIF(
            SUM(
                view_sessions
            ),
            0
        ) AS conversion_benchmark,

        SUM(
            cart_after_view_sessions
        )::numeric
        /
        NULLIF(
            SUM(
                view_sessions
            ),
            0
        ) AS view_to_cart_benchmark,

        SUM(
            purchase_after_cart_sessions
        )::numeric
        /
        NULLIF(
            SUM(
                cart_after_view_sessions
            ),
            0
        ) AS cart_to_purchase_benchmark

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
        /
        NULLIF(
            e.view_sessions,
            0
        ) AS product_conversion_rate_raw,

        e.cart_after_view_sessions::numeric
        /
        NULLIF(
            e.view_sessions,
            0
        ) AS product_view_to_cart_raw,

        e.purchase_after_cart_sessions::numeric
        /
        NULLIF(
            e.cart_after_view_sessions,
            0
        ) AS product_cart_to_purchase_raw

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

    ROUND(
        traffic_threshold::numeric,
        0
    ) AS traffic_threshold,

    ROUND(
        100 * conversion_benchmark,
        2
    ) AS conversion_benchmark_pct,

    ROUND(
        100 * view_to_cart_benchmark,
        2
    ) AS view_to_cart_benchmark_pct,

    ROUND(
        100 * cart_to_purchase_benchmark,
        2
    ) AS cart_to_purchase_benchmark_pct,

    CASE
        WHEN view_sessions >= traffic_threshold
         AND product_conversion_rate_raw
             >= conversion_benchmark
            THEN 'Protect & Scale'

        WHEN view_sessions >= traffic_threshold
         AND product_conversion_rate_raw
             < conversion_benchmark
            THEN 'Fix First'

        WHEN view_sessions < traffic_threshold
         AND product_conversion_rate_raw
             >= conversion_benchmark
            THEN 'Hidden Winner'

        ELSE 'Deprioritize'
    END AS opportunity_segment,

    ROUND(
        (
            view_sessions
            * conversion_benchmark
        )::numeric,
        2
    ) AS expected_purchase_sessions_at_benchmark,

    ROUND(
        GREATEST(
            (
                view_sessions
                * conversion_benchmark
            )
            - purchase_after_cart_sessions,
            0
        )::numeric,
        2
    ) AS conversion_gap_sessions,

    ROUND(
        100
        * product_view_to_cart_raw
        /
        NULLIF(
            view_to_cart_benchmark,
            0
        ),
        2
    ) AS view_to_cart_index,

    ROUND(
        100
        * product_cart_to_purchase_raw
        /
        NULLIF(
            cart_to_purchase_benchmark,
            0
        ),
        2
    ) AS cart_to_purchase_index

FROM scored;


CREATE UNIQUE INDEX idx_product_opportunity_product
ON portofolio_2.mv_product_opportunity_matrix (
    product_id
);

CREATE INDEX idx_product_opportunity_segment
ON portofolio_2.mv_product_opportunity_matrix (
    opportunity_segment
);

ANALYZE portofolio_2.mv_product_opportunity_matrix;


-- ---------------------------------------------------------
-- 08.9 Opportunity-segment validation
-- ---------------------------------------------------------

SELECT
    opportunity_segment,

    COUNT(*) AS products,

    SUM(
        view_sessions
    ) AS view_sessions,

    SUM(
        purchase_after_cart_sessions
    ) AS purchase_sessions,

    ROUND(
        100.0
        * SUM(
            purchase_after_cart_sessions
        )
        /
        NULLIF(
            SUM(
                view_sessions
            ),
            0
        ),
        2
    ) AS weighted_conversion_rate,

    ROUND(
        SUM(
            conversion_gap_sessions
        ),
        2
    ) AS total_conversion_gap_sessions

FROM portofolio_2.mv_product_opportunity_matrix

GROUP BY opportunity_segment

ORDER BY products DESC;

-- Observed:
--
-- Deprioritize
-- products  = 4,846
-- views     = 716,625
-- purchases = 4,324
-- conversion = 0.60%
-- gap        = 6,593.13
--
-- Fix First
-- products  = 4,499
-- views     = 3,621,423
-- purchases = 30,603
-- conversion = 0.85%
-- gap        = 24,568.63
--
-- Protect & Scale
-- products  = 3,476
-- views     = 2,514,908
-- purchases = 64,045
-- conversion = 2.55%
--
-- Hidden Winner
-- products  = 3,080
-- views     = 454,343
-- purchases = 12,354
-- conversion = 2.72%


-- ---------------------------------------------------------
-- 08.10 Fix First bottleneck diagnosis
-- ---------------------------------------------------------
--
-- Funnel indices compare each product's stage rate with the
-- weighted eligible-product benchmark.
--
-- Index < 100
-- → below benchmark
--
-- Index >= 100
-- → at or above benchmark

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
             AND view_to_cart_index
                 <= cart_to_purchase_index
                THEN 'Both — View → Cart Weaker'

            WHEN view_to_cart_index < 100
             AND cart_to_purchase_index < 100
             AND cart_to_purchase_index
                 < view_to_cart_index
                THEN 'Both — Cart → Purchase Weaker'

            ELSE 'Review'
        END AS primary_bottleneck

    FROM portofolio_2.mv_product_opportunity_matrix

    WHERE opportunity_segment = 'Fix First'
)

SELECT
    primary_bottleneck,

    COUNT(*) AS products,

    SUM(
        view_sessions
    ) AS view_sessions,

    SUM(
        purchase_after_cart_sessions
    ) AS purchase_sessions,

    ROUND(
        100.0
        * SUM(
            purchase_after_cart_sessions
        )
        /
        NULLIF(
            SUM(
                view_sessions
            ),
            0
        ),
        2
    ) AS weighted_conversion_rate,

    ROUND(
        SUM(
            conversion_gap_sessions
        ),
        2
    ) AS conversion_gap_sessions

FROM diagnosed

GROUP BY primary_bottleneck

ORDER BY conversion_gap_sessions DESC;

-- Observed:
--
-- Both — View → Cart Weaker
-- products = 895
-- views    = 923,769
-- purchases = 5,365
-- conversion = 0.58%
-- gap = 8,708.53
--
-- Both — Cart → Purchase Weaker
-- products = 1,404
-- views    = 921,233
-- purchases = 6,585
-- conversion = 0.71%
-- gap = 7,449.73
--
-- View → Cart
-- products = 1,032
-- views    = 1,090,539
-- purchases = 10,834
-- conversion = 0.99%
-- gap = 5,780.04
--
-- Cart → Purchase
-- products = 1,168
-- views    = 685,882
-- purchases = 7,819
-- conversion = 1.14%
-- gap = 2,630.33
--
-- Review = 0


-- ---------------------------------------------------------
-- 08.11 Top Fix First opportunities
-- ---------------------------------------------------------

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
             AND view_to_cart_index
                 <= cart_to_purchase_index
                THEN 'Both — View → Cart Weaker'

            WHEN view_to_cart_index < 100
             AND cart_to_purchase_index < 100
             AND cart_to_purchase_index
                 < view_to_cart_index
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


-- =========================================================
-- CATEGORY CONTEXT
-- =========================================================


-- ---------------------------------------------------------
-- 08.12 Same-category session funnel
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 analytical_session_id × 1 category_id
--
-- category_id is used instead of category_code because
-- category_code is missing on approximately 98.29% of
-- source events.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_session_category_funnel AS

WITH timestamp_category_events AS (
    SELECT
        analytical_session_id,
        user_id,
        category_id,
        event_time_utc,

        BOOL_OR(
            event_type = 'view'
        ) AS has_view_at_ts,

        BOOL_OR(
            event_type = 'cart'
        ) AS has_cart_at_ts,

        BOOL_OR(
            event_type = 'purchase'
        ) AS has_purchase_at_ts

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

        BOOL_OR(
            has_view_at_ts
        ) OVER (
            PARTITION BY
                analytical_session_id,
                category_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND CURRENT ROW
        ) AS seen_category_view

    FROM timestamp_category_events
),

after_cart AS (
    SELECT
        *,

        BOOL_OR(
            has_cart_at_ts
            AND seen_category_view
        ) OVER (
            PARTITION BY
                analytical_session_id,
                category_id
            ORDER BY event_time_utc
            ROWS BETWEEN UNBOUNDED PRECEDING
                     AND CURRENT ROW
        ) AS seen_category_cart_after_view

    FROM after_view
)

SELECT
    analytical_session_id,
    user_id,
    category_id,

    BOOL_OR(
        has_view_at_ts
    ) AS has_category_view,

    BOOL_OR(
        has_cart_at_ts
        AND seen_category_view
    ) AS has_category_cart_after_view,

    BOOL_OR(
        has_purchase_at_ts
        AND seen_category_cart_after_view
    ) AS has_category_purchase_after_cart

FROM after_cart

GROUP BY
    analytical_session_id,
    user_id,
    category_id;


CREATE INDEX idx_session_category_funnel_category
ON portofolio_2.mv_session_category_funnel (
    category_id
);

ANALYZE portofolio_2.mv_session_category_funnel;


-- ---------------------------------------------------------
-- 08.13 Category funnel performance
-- ---------------------------------------------------------

CREATE MATERIALIZED VIEW
    portofolio_2.mv_category_funnel_performance AS

SELECT
    category_id,

    COUNT(*) FILTER (
        WHERE has_category_view
    ) AS view_sessions,

    COUNT(*) FILTER (
        WHERE has_category_cart_after_view
    ) AS cart_after_view_sessions,

    COUNT(*) FILTER (
        WHERE has_category_purchase_after_cart
    ) AS purchase_after_cart_sessions,

    ROUND(
        100.0
        * COUNT(*) FILTER (
            WHERE has_category_cart_after_view
        )
        /
        NULLIF(
            COUNT(*) FILTER (
                WHERE has_category_view
            ),
            0
        ),
        2
    ) AS view_to_cart_rate,

    ROUND(
        100.0
        * COUNT(*) FILTER (
            WHERE has_category_purchase_after_cart
        )
        /
        NULLIF(
            COUNT(*) FILTER (
                WHERE has_category_cart_after_view
            ),
            0
        ),
        2
    ) AS cart_to_purchase_rate,

    ROUND(
        100.0
        * COUNT(*) FILTER (
            WHERE has_category_purchase_after_cart
        )
        /
        NULLIF(
            COUNT(*) FILTER (
                WHERE has_category_view
            ),
            0
        ),
        2
    ) AS view_to_purchase_rate

FROM portofolio_2.mv_session_category_funnel

GROUP BY category_id;


CREATE UNIQUE INDEX idx_category_funnel_performance_category
ON portofolio_2.mv_category_funnel_performance (
    category_id
);

ANALYZE portofolio_2.mv_category_funnel_performance;


-- ---------------------------------------------------------
-- 08.14 Category traffic distribution
-- ---------------------------------------------------------

SELECT
    COUNT(*) AS categories,

    ROUND(
        PERCENTILE_CONT(0.25)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS p25_views,

    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS median_views,

    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS p75_views,

    ROUND(
        PERCENTILE_CONT(0.90)
        WITHIN GROUP (
            ORDER BY view_sessions
        )::numeric,
        0
    ) AS p90_views,

    MAX(
        view_sessions
    ) AS max_views

FROM portofolio_2.mv_category_funnel_performance;

-- Observed:
-- categories = 525
-- P25        = 671
-- Median     = 2,922
-- P75        = 10,223
-- P90        = 29,439
-- Max        = 229,293


-- ---------------------------------------------------------
-- 08.15 Category-level weighted benchmark
-- ---------------------------------------------------------

SELECT
    SUM(
        view_sessions
    ) AS category_view_sessions,

    SUM(
        cart_after_view_sessions
    ) AS category_cart_sessions,

    SUM(
        purchase_after_cart_sessions
    ) AS category_purchase_sessions,

    ROUND(
        100.0
        * SUM(
            cart_after_view_sessions
        )
        /
        NULLIF(
            SUM(
                view_sessions
            ),
            0
        ),
        2
    ) AS weighted_view_to_cart_rate,

    ROUND(
        100.0
        * SUM(
            purchase_after_cart_sessions
        )
        /
        NULLIF(
            SUM(
                cart_after_view_sessions
            ),
            0
        ),
        2
    ) AS weighted_cart_to_purchase_rate,

    ROUND(
        100.0
        * SUM(
            purchase_after_cart_sessions
        )
        /
        NULLIF(
            SUM(
                view_sessions
            ),
            0
        ),
        2
    ) AS weighted_view_to_purchase_rate

FROM portofolio_2.mv_category_funnel_performance;

-- Observed benchmark:
-- View → Cart       = 15.53%
-- Cart → Purchase   = 15.07%
-- View → Purchase   =  2.34%


-- ---------------------------------------------------------
-- 08.16 High-traffic underperforming category watchlist
-- ---------------------------------------------------------
--
-- High traffic threshold:
-- P75 of category View Sessions
--
-- Category analysis is supporting context rather than a
-- second full opportunity matrix.

WITH benchmark AS (
    SELECT
        PERCENTILE_CONT(0.75)
            WITHIN GROUP (
                ORDER BY view_sessions
            ) AS high_traffic_threshold,

        SUM(
            cart_after_view_sessions
        )::numeric
        /
        NULLIF(
            SUM(
                view_sessions
            ),
            0
        ) AS view_to_cart_benchmark,

        SUM(
            purchase_after_cart_sessions
        )::numeric
        /
        NULLIF(
            SUM(
                cart_after_view_sessions
            ),
            0
        ) AS cart_to_purchase_benchmark,

        SUM(
            purchase_after_cart_sessions
        )::numeric
        /
        NULLIF(
            SUM(
                view_sessions
            ),
            0
        ) AS conversion_benchmark

    FROM portofolio_2.mv_category_funnel_performance
),

scored AS (
    SELECT
        c.*,

        b.high_traffic_threshold,
        b.view_to_cart_benchmark,
        b.cart_to_purchase_benchmark,
        b.conversion_benchmark,

        c.cart_after_view_sessions::numeric
        /
        NULLIF(
            c.view_sessions,
            0
        ) AS view_to_cart_raw,

        c.purchase_after_cart_sessions::numeric
        /
        NULLIF(
            c.cart_after_view_sessions,
            0
        ) AS cart_to_purchase_raw,

        c.purchase_after_cart_sessions::numeric
        /
        NULLIF(
            c.view_sessions,
            0
        ) AS conversion_raw

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

    ROUND(
        high_traffic_threshold::numeric,
        0
    ) AS high_traffic_threshold,

    ROUND(
        100 * view_to_cart_benchmark,
        2
    ) AS view_to_cart_benchmark,

    ROUND(
        100 * cart_to_purchase_benchmark,
        2
    ) AS cart_to_purchase_benchmark,

    ROUND(
        100 * conversion_benchmark,
        2
    ) AS conversion_benchmark,

    ROUND(
        100
        * view_to_cart_raw
        /
        NULLIF(
            view_to_cart_benchmark,
            0
        ),
        2
    ) AS view_to_cart_index,

    ROUND(
        100
        * cart_to_purchase_raw
        /
        NULLIF(
            cart_to_purchase_benchmark,
            0
        ),
        2
    ) AS cart_to_purchase_index,

    ROUND(
        GREATEST(
            view_sessions
            * conversion_benchmark
            - purchase_after_cart_sessions,
            0
        ),
        2
    ) AS conversion_gap_sessions

FROM scored

WHERE view_sessions >= high_traffic_threshold
  AND conversion_raw < conversion_benchmark

ORDER BY
    conversion_gap_sessions DESC,
    view_sessions DESC

LIMIT 20;


-- =========================================================
-- METHODOLOGICAL NOTES
-- =========================================================
--
-- 1. Product opportunity ranking uses same-product sequential
--    funnel progression, not raw event-count ratios.
--
-- 2. Products require at least 100 View Sessions to enter the
--    Product Opportunity Matrix. This reduces instability
--    from very small denominators.
--
-- 3. Traffic classification uses median View Sessions among
--    eligible products.
--
-- 4. Conversion classification uses weighted View → Purchase
--    performance among eligible products.
--
-- 5. conversion_gap_sessions represents:
--
--    expected qualified purchase sessions at benchmark
--    minus
--    observed qualified purchase sessions.
--
--    It is a diagnostic benchmark-equivalent gap.
--
--    It is NOT:
--    - lost orders
--    - forecast revenue
--    - guaranteed incremental purchases
--
-- 6. observed_purchase_value represents all positive-price
--    purchase-event value associated with each product in the
--    valid analytical-session layer.
--
--    It is NOT limited to purchases completing the qualified
--    View → Cart → Purchase sequence.
--
-- 7. Hidden Winners are candidates for controlled exposure
--    testing. Historical conversion does not prove that the
--    same performance will persist at higher traffic levels.
--
-- 8. category_id is used as the primary category dimension
--    because category_code coverage is too sparse.
--
-- 9. Category results are supporting context and are not used
--    to infer the causal source of product-level conversion
--    weakness.
--
-- =========================================================
