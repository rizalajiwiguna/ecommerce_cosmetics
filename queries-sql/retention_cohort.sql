--1. Customer monthly purchase activity
--Grain:1 row = 1 user × 1 purchase month
CREATE MATERIALIZED VIEW
    portofolio_2.mv_customer_monthly_purchase AS
SELECT
    user_id,
    DATE_TRUNC('month',event_time_utc)::date AS purchase_month,
    COUNT(*) AS purchase_events,
    COUNT(DISTINCT analytical_session_id) AS purchase_sessions,
    COUNT(*) FILTER (WHERE is_valid_monetary_purchase) AS valid_monetary_purchase_events,
    SUM(observed_purchase_value) AS observed_purchase_value,
    COUNT(DISTINCT product_id) AS distinct_products_purchased
FROM portofolio_2.mv_events_sessionized
WHERE event_type = 'purchase'
GROUP BY 1,2;

CREATE UNIQUE INDEX idx_customer_monthly_purchase
ON portofolio_2.mv_customer_monthly_purchase (
    user_id,
    purchase_month
);

ANALYZE portofolio_2.mv_customer_monthly_purchase;

--2. Monthly purchase-layer reconciliation
SELECT
    COUNT(*) AS user_month_rows,
    COUNT(DISTINCT user_id) AS purchasing_users,
    MIN(purchase_month) AS first_purchase_month,
    MAX(purchase_month) AS last_purchase_month,
    SUM(purchase_events) AS total_purchase_events,
    SUM(valid_monetary_purchase_events) AS valid_monetary_purchase_events,
    ROUND(SUM(observed_purchase_value),2) AS total_observed_purchase_value
FROM portofolio_2.mv_customer_monthly_purchase;
--Observed:
--user_month_rows                = 136,859
--purchasing_users               = 110,500
--first_purchase_month           = 2019-10-01
--last_purchase_month            = 2020-02-01
--total_purchase_events          = 1,286,898
--valid monetary purchase events = 1,286,771
--observed purchase value        = 6,351,305.66

--3. Purchase cohort assignment
CREATE MATERIALIZED VIEW portofolio_2.mv_customer_purchase_cohort AS
WITH cohort AS (
    SELECT
        user_id,
        MIN(purchase_month) AS cohort_month
    FROM portofolio_2.mv_customer_monthly_purchase
    GROUP BY user_id
)
SELECT
    m.user_id,
    c.cohort_month,
    m.purchase_month,
    ((EXTRACT(YEAR FROM m.purchase_month) - EXTRACT(YEAR FROM c.cohort_month)) * 12 + (EXTRACT(MONTH FROM m.purchase_month) - EXTRACT(MONTH FROM c.cohort_month)))::INT AS cohort_month_number,
    m.purchase_events,
    m.purchase_sessions,
    m.valid_monetary_purchase_events,
    m.observed_purchase_value,
    m.distinct_products_purchased
FROM portofolio_2.mv_customer_monthly_purchase m
JOIN cohort c ON m.user_id = c.user_id;

CREATE UNIQUE INDEX idx_customer_purchase_cohort
ON portofolio_2.mv_customer_purchase_cohort (user_id, purchase_month);
CREATE INDEX idx_customer_purchase_cohort_month
ON portofolio_2.mv_customer_purchase_cohort (cohort_month,cohort_month_number);

ANALYZE portofolio_2.mv_customer_purchase_cohort;

--4. Cohort assignment validation
SELECT
    COUNT(DISTINCT user_id) AS cohort_customers,
    MIN(cohort_month_number) AS min_cohort_month_number,
    MAX(cohort_month_number) AS max_cohort_month_number,
    COUNT(*) FILTER(WHERE cohort_month_number < 0) AS invalid_negative_months
FROM portofolio_2.mv_customer_purchase_cohort;
--Observed:
--cohort_customers           = 110,500
--min cohort month number    = 0
--max cohort month number    = 4
--invalid negative months    = 0

--5. Cohort sizes
SELECT
    cohort_month,
    COUNT(DISTINCT user_id) AS cohort_size
FROM portofolio_2.mv_customer_purchase_cohort
WHERE cohort_month_number = 0
GROUP BY cohort_month
ORDER BY cohort_month;
--Observed:
--Oct 2019 = 25,760
--Nov 2019 = 26,758
--Dec 2019 = 19,701
--Jan 2020 = 20,422
--Feb 2020 = 17,859

--6. Observable retention long table
--Explicitly distinguishes:
--0 = observable month with zero retained customers
--NULL = not observable beyond dataset window
WITH dataset_boundary AS (
    SELECT MAX(purchase_month) AS max_purchase_month
    FROM portofolio_2.mv_customer_purchase_cohort
),
cohort_size AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT user_id) AS cohort_size
    FROM portofolio_2.mv_customer_purchase_cohort
    WHERE cohort_month_number = 0
    GROUP BY cohort_month
),
observable_months AS (
    SELECT
        c.cohort_month,
        c.cohort_size,
        gs.cohort_month_number
    FROM cohort_size AS c
    CROSS JOIN dataset_boundary AS b
    CROSS JOIN LATERAL GENERATE_SERIES(
        0,
        ((EXTRACT(YEAR FROM b.max_purchase_month) - EXTRACT(YEAR FROM c.cohort_month)) * 12 + (EXTRACT(MONTH FROM b.max_purchase_month) - EXTRACT(MONTH FROM c.cohort_month)))::INT) AS gs(cohort_month_number)
),
retained AS (
    SELECT
        cohort_month,
        cohort_month_number,
        COUNT(DISTINCT user_id) AS retained_customers
    FROM portofolio_2.mv_customer_purchase_cohort
    GROUP BY
        cohort_month,
        cohort_month_number
)
SELECT
    o.cohort_month,
    o.cohort_month_number,
    o.cohort_size,
    COALESCE(r.retained_customers, 0) AS retained_customers,
    ROUND(100.0 * COALESCE(r.retained_customers, 0) / NULLIF(o.cohort_size, 0), 2) AS retention_rate
FROM observable_months AS o
LEFT JOIN retained AS r 
    ON o.cohort_month = r.cohort_month
    AND o.cohort_month_number = r.cohort_month_number
ORDER BY
    o.cohort_month,
    o.cohort_month_number;

--7. New-observed vs returning buyers
SELECT
    purchase_month,
    COUNT(DISTINCT user_id) AS active_buyers,
    COUNT(DISTINCT user_id) FILTER(WHERE purchase_month = cohort_month) AS new_observed_buyers,
    COUNT(DISTINCT user_id) FILTER(WHERE purchase_month > cohort_month) AS returning_buyers,
    ROUND(100.0 * COUNT(DISTINCT user_id) FILTER(WHERE purchase_month > cohort_month)/NULLIF(COUNT(DISTINCT user_id),0),2) AS returning_buyer_share
FROM portofolio_2.mv_customer_purchase_cohort
GROUP BY purchase_month
ORDER BY purchase_month;
--Observed returning-buyer share:
--Oct =  0.00%
--Nov = 15.11%
--Dec = 23.08%
--Jan = 27.62%
--Feb = 30.65%
--October returning buyer share is zero by cohort definition,
--NOT evidence that no pre-existing customers existed.

--8. New vs returning historical value contribution
SELECT
    purchase_month,
    ROUND(SUM(observed_purchase_value), 2) AS total_observed_purchase_value,
    ROUND(COALESCE(SUM(observed_purchase_value) FILTER (WHERE purchase_month = cohort_month), 0),2) AS new_buyer_observed_value,
    ROUND(COALESCE(SUM(observed_purchase_value) FILTER (WHERE purchase_month > cohort_month), 0),2) AS returning_buyer_observed_value,
    ROUND(100.0 * COALESCE(SUM(observed_purchase_value) FILTER (WHERE purchase_month > cohort_month), 0)/ NULLIF(SUM(observed_purchase_value), 0),2) AS returning_value_share
FROM portofolio_2.mv_customer_purchase_cohort
GROUP BY purchase_month
ORDER BY purchase_month;

/*
-- Observed returning historical value share:
-- Oct =  0.00%
-- Nov = 21.08%
-- Dec = 28.94%
-- Jan = 34.49%
-- Feb = 37.96%
*/

/*
BUSINESS INTERPRETATION
1. October is a boundary cohort because the dataset begins on October 1, 2019. It may include customers who had purchased before the observation window.
2. Post-boundary M1 retention is relatively stable:
-Nov = 9.78%
-Dec = 8.52%
-Jan = 8.86%
-Weighted Nov–Jan M1 retention ≈ 9.13%.
3. Increasing returning-buyer share across calendar months does NOT automatically mean retention improved, because the pool of previously observed buyers grows over time.
4. Returning buyers consistently contribute a larger share of Observed Purchase Value than their share of active buyers.
5. Observed Purchase Value is a behavioral monetary metric, not profit, margin, or confirmed accounting revenue.
*/
