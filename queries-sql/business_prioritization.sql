-- =========================================================
-- BEAUTYCOMMERCE — CUSTOMER JOURNEY, CONVERSION
-- & RETENTION ANALYTICS
-- =========================================================
-- 13. BUSINESS PRIORITIZATION
-- =========================================================
--
-- Project:
-- BeautyCommerce — Customer Journey, Conversion
-- & Retention Analytics
--
-- Depends on:
-- portofolio_2.mv_product_opportunity_matrix
-- portofolio_2.mv_customer_rfm_segment
-- portofolio_2.mv_customer_historical_value_status
--
-- Produces:
-- portofolio_2.mv_product_action_priority
-- portofolio_2.mv_customer_action_priority
--
-- Analytical timezone:
-- UTC
--
-- Purpose:
-- Convert validated analytical findings into explicit
-- product-level and customer-level action priorities.
--
-- Framework:
--
-- Data
--   ↓
-- Diagnosis
--   ↓
-- Business Impact
--   ↓
-- Priority
--   ↓
-- Action
--   ↓
-- Experiment
--   ↓
-- KPI
--
-- Important:
-- Recommended actions represent hypotheses for testing.
-- No causal impact is claimed from observational data alone.
--
-- =========================================================


-- =========================================================
-- PRODUCT ACTION LAYER
-- =========================================================


-- ---------------------------------------------------------
-- 13.1 Product action priority
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 eligible product
--
-- Eligible products originate from the Product Opportunity
-- Matrix and therefore have:
--
-- view_sessions >= 100
--
-- Fix First products are separated according to the weaker
-- funnel stage relative to eligible-product benchmarks.

CREATE MATERIALIZED VIEW
    portofolio_2.mv_product_action_priority AS

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
)

SELECT
    *,

    CASE
        WHEN opportunity_segment = 'Fix First'
         AND primary_bottleneck IN (
             'View → Cart',
             'Both — View → Cart Weaker'
         )
            THEN 'Priority 1 — Pre-Cart Optimization'

        WHEN opportunity_segment = 'Fix First'
         AND primary_bottleneck IN (
             'Cart → Purchase',
             'Both — Cart → Purchase Weaker'
         )
            THEN 'Priority 2 — Post-Cart Optimization'

        WHEN opportunity_segment = 'Protect & Scale'
            THEN 'Protect & Scale'

        WHEN opportunity_segment = 'Hidden Winner'
            THEN 'Increase Exposure Test'

        ELSE 'Low Priority'
    END AS business_action

FROM diagnosed;


CREATE UNIQUE INDEX idx_product_action_priority_product
ON portofolio_2.mv_product_action_priority (
    product_id
);

CREATE INDEX idx_product_action_priority_action
ON portofolio_2.mv_product_action_priority (
    business_action
);

ANALYZE portofolio_2.mv_product_action_priority;


-- ---------------------------------------------------------
-- 13.2 Product-action validation
-- ---------------------------------------------------------

SELECT
    business_action,

    COUNT(*)
        AS products,

    SUM(
        view_sessions
    ) AS view_sessions,

    SUM(
        purchase_after_cart_sessions
    ) AS qualified_purchase_sessions,

    ROUND(
        SUM(
            conversion_gap_sessions
        ),
        2
    ) AS conversion_gap_sessions

FROM portofolio_2.mv_product_action_priority

GROUP BY business_action

ORDER BY conversion_gap_sessions DESC;

-- Observed:
--
-- Priority 1 — Pre-Cart Optimization
-- products                    = 1,927
-- view sessions               = 2,014,308
-- qualified purchase sessions =    16,199
-- conversion gap              = 14,488.57
--
-- Priority 2 — Post-Cart Optimization
-- products                    = 2,572
-- view sessions               = 1,607,115
-- qualified purchase sessions =    14,404
-- conversion gap              = 10,080.06
--
-- Low Priority
-- products                    = 4,846
-- view sessions               =   716,625
-- qualified purchase sessions =     4,324
-- conversion gap              =  6,593.13
--
-- Increase Exposure Test
-- products                    = 3,080
-- view sessions               =   454,343
-- qualified purchase sessions =    12,354
-- conversion gap              = 0
--
-- Protect & Scale
-- products                    = 3,476
-- view sessions               = 2,514,908
-- qualified purchase sessions =    64,045
-- conversion gap              = 0
--
-- Reconciliation:
-- Total eligible products = 15,901
--
-- Fix First products:
-- 1,927 + 2,572 = 4,499
--
-- Fix First conversion gap:
-- 14,488.57 + 10,080.06
-- = 24,568.63


-- ---------------------------------------------------------
-- 13.3 Fix First opportunity distribution
-- ---------------------------------------------------------
-- Measures how the benchmark-equivalent opportunity gap is
-- distributed between the two main action priorities.

SELECT
    business_action,

    COUNT(*)
        AS products,

    ROUND(
        100.0
        * COUNT(*)
        /
        SUM(
            COUNT(*)
        ) OVER (),
        2
    ) AS product_share_pct,

    ROUND(
        SUM(
            conversion_gap_sessions
        ),
        2
    ) AS conversion_gap_sessions,

    ROUND(
        100.0
        * SUM(
            conversion_gap_sessions
        )
        /
        SUM(
            SUM(
                conversion_gap_sessions
            )
        ) OVER (),
        2
    ) AS gap_share_pct

FROM portofolio_2.mv_product_action_priority

WHERE business_action IN (
    'Priority 1 — Pre-Cart Optimization',
    'Priority 2 — Post-Cart Optimization'
)

GROUP BY business_action

ORDER BY conversion_gap_sessions DESC;

-- Approximate observed distribution:
--
-- Pre-Cart Optimization
-- ~59% of Fix First conversion gap
--
-- Post-Cart Optimization
-- ~41% of Fix First conversion gap
--
-- This indicates that the majority of the observed product
-- opportunity gap involves weaker View → Cart performance.
--
-- It does NOT establish the causal reason for that weakness.


-- =========================================================
-- CUSTOMER ACTION LAYER
-- =========================================================


-- ---------------------------------------------------------
-- 13.4 Customer action priority
-- ---------------------------------------------------------
-- Grain:
-- 1 row = 1 observed purchasing customer
--
-- Priority logic combines:
-- - RFM segment
-- - recency status
-- - historical value status
-- - historical frequency profile

CREATE MATERIALIZED VIEW
    portofolio_2.mv_customer_action_priority AS

SELECT
    h.user_id,

    h.recency_days,
    h.frequency_purchase_sessions,
    h.monetary_observed_value,

    h.r_score,
    h.f_score,
    h.m_score,

    r.recency_band,
    r.frequency_band,
    r.monetary_band,
    r.rfm_segment,

    h.historical_value_status,
    h.frequency_profile,

    CASE
        WHEN r.rfm_segment = 'Champions'
            THEN 'Protect'

        WHEN r.rfm_segment = 'Loyal High-Value'
         AND r.recency_band = 'Recent'
            THEN 'Protect'

        WHEN r.rfm_segment = 'Recent High-Value'
            THEN 'Accelerate Second Purchase'

        WHEN h.historical_value_status
                = 'High-Value Watchlist'
         AND h.frequency_profile IN (
             'Repeat',
             'High Frequency'
         )
            THEN 'Prevent Deterioration'

        WHEN h.historical_value_status
                = 'Historical Value at Risk'
         AND h.frequency_profile IN (
             'Repeat',
             'High Frequency'
         )
            THEN 'High-Priority Reactivation'

        WHEN h.historical_value_status
                = 'Historical Value at Risk'
         AND h.frequency_profile = 'One-Time'
            THEN 'Selective Reactivation'

        WHEN r.rfm_segment = 'Promising'
            THEN 'Nurture'

        ELSE 'Lower Priority'
    END AS customer_action

FROM portofolio_2.mv_customer_historical_value_status h

JOIN portofolio_2.mv_customer_rfm_segment r
    ON h.user_id = r.user_id;


CREATE UNIQUE INDEX idx_customer_action_priority_user
ON portofolio_2.mv_customer_action_priority (
    user_id
);

CREATE INDEX idx_customer_action_priority_action
ON portofolio_2.mv_customer_action_priority (
    customer_action
);

ANALYZE portofolio_2.mv_customer_action_priority;


-- ---------------------------------------------------------
-- 13.5 Customer-action validation
-- ---------------------------------------------------------

SELECT
    customer_action,

    COUNT(*)
        AS customers,

    ROUND(
        100.0
        * COUNT(*)
        / SUM(
            COUNT(*)
        ) OVER (),
        2
    ) AS customer_share_pct,

    ROUND(
        SUM(
            monetary_observed_value
        ),
        2
    ) AS historical_observed_value,

    ROUND(
        100.0
        * SUM(
            monetary_observed_value
        )
        /
        SUM(
            SUM(
                monetary_observed_value
            )
        ) OVER (),
        2
    ) AS historical_value_share_pct

FROM portofolio_2.mv_customer_action_priority

GROUP BY customer_action

ORDER BY historical_observed_value DESC;

-- Observed:
--
-- Protect
-- customers = 11,944
-- customer share = 10.81%
-- historical value = 2,093,143.54
-- value share = 32.96%
--
-- Lower Priority
-- customers = 53,080
-- customer share = 48.04%
-- historical value = 1,700,503.96
-- value share = 26.77%
--
-- Prevent Deterioration
-- customers = 6,120
-- customer share = 5.54%
-- historical value = 788,681.36
-- value share = 12.42%
--
-- Accelerate Second Purchase
-- customers = 8,790
-- customer share = 7.95%
-- historical value = 694,510.59
-- value share = 10.93%
--
-- Nurture
-- customers = 23,742
-- customer share = 21.49%
-- historical value = 494,997.66
-- value share = 7.79%
--
-- Selective Reactivation
-- customers = 5,732
-- customer share = 5.19%
-- historical value = 444,203.81
-- value share = 6.99%
--
-- High-Priority Reactivation
-- customers = 1,092
-- customer share = 0.99%
-- historical value = 135,264.74
-- value share = 2.13%
--
-- Reconciliation:
-- customers = 110,500
-- historical Observed Purchase Value = 6,351,305.66


-- ---------------------------------------------------------
-- 13.6 Strategic customer concentration
-- ---------------------------------------------------------
-- Protect + Prevent Deterioration
-- + Accelerate Second Purchase
--
-- represent the core proactive customer-development groups.

SELECT
    COUNT(*)
        AS priority_customers,

    ROUND(
        100.0
        * COUNT(*)
        /
        (
            SELECT COUNT(*)
            FROM portofolio_2.mv_customer_action_priority
        ),
        2
    ) AS customer_share_pct,

    ROUND(
        SUM(
            monetary_observed_value
        ),
        2
    ) AS historical_observed_value,

    ROUND(
        100.0
        * SUM(
            monetary_observed_value
        )
        /
        (
            SELECT
                SUM(
                    monetary_observed_value
                )
            FROM portofolio_2.mv_customer_action_priority
        ),
        2
    ) AS historical_value_share_pct

FROM portofolio_2.mv_customer_action_priority

WHERE customer_action IN (
    'Protect',
    'Prevent Deterioration',
    'Accelerate Second Purchase'
);

-- Observed:
-- customer share ≈ 24.30%
-- historical value share ≈ 56.31%
--
-- Interpretation:
-- A relatively concentrated subset of purchasing customers
-- represents more than half of historical Observed Purchase
-- Value.


-- =========================================================
-- ACTION & EXPERIMENT FRAMEWORK
-- =========================================================
--
-- PRODUCT PRIORITY 1
-- PRE-CART OPTIMIZATION
--
-- Target:
-- High-traffic Fix First products with weaker View → Cart
-- performance.
--
-- Candidate interventions:
-- - product information
-- - product imagery/content presentation
-- - price presentation
-- - merchandising
--
-- Primary KPI:
-- Same-product View → Cart Rate
--
-- Secondary KPI:
-- Same-product View → Purchase Rate
--
-- Guardrail:
-- Cart → Purchase Rate
--
--
-- PRODUCT PRIORITY 2
-- POST-CART OPTIMIZATION
--
-- Target:
-- Fix First products with weaker Cart → Purchase performance.
--
-- Candidate interventions:
-- - checkout simplification
-- - payment visibility
-- - shipping-cost transparency
-- - stock confirmation
-- - cart reminder treatment
--
-- Primary KPI:
-- Cart → Purchase Rate
--
-- Secondary KPI:
-- View → Purchase Rate
--
-- Future instrumentation required:
-- - checkout_step
-- - payment_status
-- - shipping_fee
-- - inventory_status
--
--
-- CUSTOMER PRIORITY
-- ACCELERATE SECOND PURCHASE
--
-- Target:
-- Recent High-Value customers with only one observed
-- purchase session.
--
-- Candidate interventions:
-- - post-purchase follow-up
-- - related-product recommendation
-- - replenishment reminder
-- - controlled incentive
--
-- Primary KPI:
-- 30-day second-purchase rate
--
-- Secondary KPI:
-- - days to second purchase
-- - Observed Purchase Value per targeted customer
--
-- Future guardrails:
-- - promotion cost
-- - gross margin
--
--
-- CUSTOMER PRIORITY
-- PREVENT DETERIORATION
--
-- Target:
-- High-Value Watchlist customers with Repeat or
-- High-Frequency historical behavior.
--
-- Primary KPI:
-- Subsequent purchase rate
--
-- Secondary KPI:
-- Time to next purchase
--
--
-- CUSTOMER PRIORITY
-- HIGH-PRIORITY REACTIVATION
--
-- Target:
-- Historical Value at Risk customers with Repeat or
-- High-Frequency historical behavior.
--
-- Primary KPI:
-- Reactivation purchase rate
--
-- Secondary KPI:
-- - time to reactivation
-- - Observed Purchase Value per reactivated customer
--
--
-- CUSTOMER PRIORITY
-- SELECTIVE REACTIVATION
--
-- Target:
-- Historical Value at Risk customers with only one observed
-- purchase session.
--
-- These customers remain historically valuable, but have
-- weaker historical evidence of repeat engagement.
--
--
-- HIDDEN WINNERS
--
-- Action:
-- Controlled exposure testing.
--
-- High historical conversion at lower traffic does not prove
-- that conversion will remain stable when exposure increases.
--
-- =========================================================


-- =========================================================
-- FINAL METHODOLOGICAL GUARDRAILS
-- =========================================================
--
-- Do NOT interpret:
--
-- purchase_sessions
-- as confirmed orders.
--
-- purchase_events
-- as units sold.
--
-- observed_purchase_value
-- as profit, margin, or confirmed accounting revenue.
--
-- conversion_gap_sessions
-- as lost orders, lost revenue, or guaranteed incremental
-- purchases.
--
-- Historical Value at Risk
-- as forecast future loss.
--
-- RFM segments
-- as predicted churn probability or Customer Lifetime Value.
--
-- returning buyers
-- as automatically loyal customers.
--
-- observational associations
-- as causal effects.
--
-- Actions in this file are prioritization hypotheses.
-- Their causal impact requires controlled experimentation.
--
-- =========================================================
