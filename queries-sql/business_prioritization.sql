-- =========================================================
-- BEAUTYCOMMERCE — CUSTOMER JOURNEY, CONVERSION
-- & RETENTION ANALYTICS
-- =========================================================
-- 13. BUSINESS PRIORITIZATION
-- =========================================================
--
-- Purpose:
-- Convert analytical findings into explicit product and
-- customer action layers.
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
-- No causal impact is claimed before experimentation.
--
-- =========================================================


-- =========================================================
-- PRODUCT ACTION LAYER
-- =========================================================


-- ---------------------------------------------------------
-- 13.1 Product action priority
-- ---------------------------------------------------------

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
-- 13.2 Product-action summary
-- ---------------------------------------------------------

SELECT
    business_action,

    COUNT(*) AS products,

    SUM(view_sessions)
        AS view_sessions,

    SUM(purchase_after_cart_sessions)
        AS qualified_purchase_sessions,

    ROUND(
        SUM(conversion_gap_sessions),
        2
    ) AS conversion_gap_sessions

FROM portofolio_2.mv_product_action_priority

GROUP BY business_action

ORDER BY conversion_gap_sessions DESC;

-- Observed:
--
-- Priority 1 — Pre-Cart Optimization
-- products = 1,927
-- traffic  = 2,014,308
-- gap      = 14,488.57
--
-- Priority 2 — Post-Cart Optimization
-- products = 2,572
-- traffic  = 1,607,115
-- gap      = 10,080.06
--
-- Low Priority
-- products = 4,846
-- gap      = 6,593.13
--
-- Increase Exposure Test
-- products = 3,080
--
-- Protect & Scale
-- products = 3,476


-- =========================================================
-- CUSTOMER ACTION LAYER
-- =========================================================


-- ---------------------------------------------------------
-- 13.3 Customer action priority
-- ---------------------------------------------------------

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
-- 13.4 Customer-action summary
-- ---------------------------------------------------------

SELECT
    customer_action,

    COUNT(*) AS customers,

    ROUND(
        100.0 * COUNT(*)
        / SUM(COUNT(*)) OVER (),
        2
    ) AS customer_share_pct,

    ROUND(
        SUM(monetary_observed_value),
        2
    ) AS historical_observed_value,

    ROUND(
        100.0 * SUM(monetary_observed_value)
        / SUM(
            SUM(monetary_observed_value)
        ) OVER (),
        2
    ) AS historical_value_share_pct

FROM portofolio_2.mv_customer_action_priority

GROUP BY customer_action

ORDER BY historical_observed_value DESC;

-- Observed:
--
-- Protect
-- 11,944 customers | 32.96% value
--
-- Lower Priority
-- 53,080 customers | 26.77% value
--
-- Prevent Deterioration
-- 6,120 customers | 12.42% value
--
-- Accelerate Second Purchase
-- 8,790 customers | 10.93% value
--
-- Nurture
-- 23,742 customers | 7.79% value
--
-- Selective Reactivation
-- 5,732 customers | 6.99% value
--
-- High-Priority Reactivation
-- 1,092 customers | 2.13% value


-- =========================================================
-- EXPERIMENT FRAMEWORK
-- =========================================================
--
-- PRIORITY 1 — PRE-CART OPTIMIZATION
--
-- Target:
-- High-traffic Fix First products whose primary observed
-- weakness is View → Cart.
--
-- Candidate interventions:
-- - product-page information
-- - imagery / content presentation
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
-- PRIORITY 2 — POST-CART OPTIMIZATION
--
-- Target:
-- Fix First products whose primary observed weakness is
-- Cart → Purchase.
--
-- Candidate interventions:
-- - checkout simplification
-- - payment visibility
-- - shipping-cost transparency
-- - stock confirmation
-- - cart reminders
--
-- Primary KPI:
-- Cart → Purchase Rate
--
-- Secondary KPI:
-- View → Purchase Rate
--
-- Required future instrumentation:
-- checkout_step
-- payment_status
-- shipping_fee
-- inventory_status
--
--
-- PRIORITY 3 — ACCELERATE SECOND PURCHASE
--
-- Target:
-- Recent High-Value one-time observed buyers.
--
-- Candidate interventions:
-- - targeted post-purchase follow-up
-- - related-product recommendation
-- - replenishment reminder
-- - controlled incentive
--
-- Primary KPI:
-- 30-day second-purchase rate
--
-- Secondary:
-- Days to second purchase
-- Observed Purchase Value per targeted customer
--
-- Required guardrails:
-- discount cost
-- margin
--
--
-- PRIORITY 4 — PREVENT DETERIORATION
--
-- Target:
-- High-Value Watchlist customers with repeat or
-- high-frequency historical behavior.
--
-- Primary KPI:
-- Subsequent purchase rate
--
-- Secondary:
-- Time to next purchase
--
--
-- PRIORITY 5 — REACTIVATION
--
-- Target:
-- Historical Value at Risk customers.
--
-- Highest operational priority:
-- Repeat / High-Frequency high-value stale customers.
--
-- Primary KPI:
-- Reactivation purchase rate
--
-- Secondary:
-- Time to reactivation
-- Observed Purchase Value per reactivated customer
--
--
-- HIDDEN WINNERS
--
-- Action:
-- Controlled exposure test.
--
-- Do NOT automatically scale all Hidden Winners because
-- historical conversion may change when exposure increases.
--
-- =========================================================


-- =========================================================
-- FINAL METHODOLOGICAL GUARDRAILS
-- =========================================================
--
-- Do not label:
--
-- purchase_sessions
-- as confirmed orders.
--
-- observed_purchase_value
-- as profit, margin, or confirmed revenue.
--
-- conversion_gap_sessions
-- as lost orders or forecast incremental purchases.
--
-- historical value at risk
-- as predicted future revenue loss.
--
-- RFM segments
-- as predicted churn probabilities.
--
-- observational associations
-- as causal effects.
--
-- =========================================================
