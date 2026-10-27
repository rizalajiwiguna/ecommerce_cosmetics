--1. RFM base
--Grain:1 row = 1 observed purchasing customer
CREATE MATERIALIZED VIEW
    portofolio_2.mv_customer_rfm_base AS
SELECT
    user_id,
    DATE '2020-03-01' AS analysis_date,
    first_purchase_utc,
    last_purchase_utc,
    DATE '2020-03-01' - last_purchase_utc::date AS recency_days,
    purchase_sessions AS frequency_purchase_sessions,
    purchase_events,
    valid_monetary_purchase_events,
    observed_purchase_value AS monetary_observed_value,
    active_purchase_days,
    active_purchase_months,
    distinct_products_purchased,
    avg_observed_value_per_purchase_session,
    purchase_span_days,
    avg_days_between_purchase_sessions
FROM portofolio_2.mv_customer_purchase_summary;

CREATE UNIQUE INDEX idx_customer_rfm_user
ON portofolio_2.mv_customer_rfm_base (user_id);

CREATE INDEX idx_customer_rfm_recency
ON portofolio_2.mv_customer_rfm_base (recency_days);

ANALYZE portofolio_2.mv_customer_rfm_base;

--2 RFM base reconciliation
SELECT
    COUNT(*) AS customers,
    COUNT(DISTINCT user_id) AS unique_customers,
    MIN(recency_days) AS min_recency_days,
    MAX(recency_days) AS max_recency_days,
    SUM(frequency_purchase_sessions) AS total_purchase_sessions,
    SUM(purchase_events) AS total_purchase_events,
    SUM(valid_monetary_purchase_events) AS valid_monetary_purchase_events,
    ROUND(SUM(monetary_observed_value),2) AS total_monetary_observed_value
FROM portofolio_2.mv_customer_rfm_base;
--Observed:
--customers                       = 110,500
--unique_customers                = 110,500
--min_recency_days                = 1
--max_recency_days                = 152
--total_purchase_sessions         = 157,573
--total_purchase_events           = 1,286,898
--valid_monetary_purchase_events  = 1,286,771
--total_monetary_observed_value   = 6,351,305.66

--3 RFM distribution
SELECT
    ROUND(
        PERCENTILE_CONT(0.25)
        WITHIN GROUP(ORDER BY recency_days)::numeric,0) AS p25_recency,
    ROUND(PERCENTILE_CONT(0.50)
        WITHIN GROUP(ORDER BY recency_days)::numeric,0) AS median_recency,
    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP(ORDER BY recency_days)::numeric,0) AS p75_recency,
    ROUND(
        PERCENTILE_CONT(0.90)
        WITHIN GROUP(ORDER BY recency_days)::numeric,0) AS p90_recency,
    ROUND(
        PERCENTILE_CONT(0.25)
        WITHIN GROUP(ORDER BY frequency_purchase_sessions)::numeric,0) AS p25_frequency,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP(ORDER BY frequency_purchase_sessions)::numeric,0) AS median_frequency,
    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP(ORDER BY frequency_purchase_sessions)::numeric,0) AS p75_frequency,
    ROUND(
        PERCENTILE_CONT(0.90)
        WITHIN GROUP(ORDER BY frequency_purchase_sessions)::numeric,0) AS p90_frequency,
    ROUND(
        PERCENTILE_CONT(0.95)
        WITHIN GROUP(ORDER BY frequency_purchase_sessions)::numeric,0) AS p95_frequency,
    ROUND(
        PERCENTILE_CONT(0.25)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS p25_monetary,
    ROUND(
        PERCENTILE_CONT(0.50)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS median_monetary,
    ROUND(
        PERCENTILE_CONT(0.75)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS p75_monetary,
    ROUND(
        PERCENTILE_CONT(0.90)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS p90_monetary,
    ROUND(
        PERCENTILE_CONT(0.95)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS p95_monetary
FROM portofolio_2.mv_customer_rfm_base;
--Observed:
--Recency P25 / P50 / P75 / P90 = 32 / 71 / 106 / 134
--Frequency P25 / P50 / P75     = 1 / 1 / 1
--Frequency P90 / P95           = 2 / 3
--Monetary P25 / P50 / P75      = 16.28 / 33.22 / 61.58
--Monetary P90 / P95            = 122.25 / 192.78

--4 Frequency distribution
SELECT
    frequency_purchase_sessions,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*)/ SUM(COUNT(*)) OVER (),2) AS customer_share_pct
FROM portofolio_2.mv_customer_rfm_base
GROUP BY frequency_purchase_sessions
ORDER BY frequency_purchase_sessions
LIMIT 15;
--Key finding:
--1 purchase session = 78.27% of observed buyers.
--Therefore frequency is NOT scored using NTILE(), because
--doing so would split customers with identical frequency
--across different scores.

--5. R and M percentile thresholds
SELECT
    ROUND(
        PERCENTILE_CONT(0.20)
        WITHIN GROUP(ORDER BY recency_days)::numeric,0) AS r_p20,
    ROUND(
        PERCENTILE_CONT(0.40)
        WITHIN GROUP(ORDER BY recency_days)::numeric,0) AS r_p40,
    ROUND(
        PERCENTILE_CONT(0.60)
        WITHIN GROUP(ORDER BY recency_days)::numeric,0) AS r_p60,
    ROUND(
        PERCENTILE_CONT(0.80)
        WITHIN GROUP(ORDER BY recency_days)::numeric,0) AS r_p80,
    ROUND(
        PERCENTILE_CONT(0.20)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS m_p20,
    ROUND(
        PERCENTILE_CONT(0.40)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS m_p40,
    ROUND(
        PERCENTILE_CONT(0.60)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS m_p60,
    ROUND(
        PERCENTILE_CONT(0.80)
        WITHIN GROUP(ORDER BY monetary_observed_value)::numeric,2) AS m_p80
FROM portofolio_2.mv_customer_rfm_base;
/*
Observed:
R thresholds = 25 / 51 / 87 / 115 days
M thresholds = 14.20 / 24.96 / 41.92 / 74.44

6 Tie-aware RFM scoring
R: Lower recency is better.
F:
F1 = 1 purchase session
F2 = 2
F3 = 3
F4 = 4–5
F5 = 6+
M:Higher historical observed value is better.
*/

CREATE MATERIALIZED VIEW
    portofolio_2.mv_customer_rfm_scored AS
WITH thresholds AS (
    SELECT
        PERCENTILE_CONT(0.20)
            WITHIN GROUP(ORDER BY recency_days) AS r_p20,
        PERCENTILE_CONT(0.40)
            WITHIN GROUP(ORDER BY recency_days) AS r_p40,
        PERCENTILE_CONT(0.60)
            WITHIN GROUP(ORDER BY recency_days) AS r_p60,
        PERCENTILE_CONT(0.80)
            WITHIN GROUP(ORDER BY recency_days) AS r_p80,
        PERCENTILE_CONT(0.20)
            WITHIN GROUP(ORDER BY monetary_observed_value) AS m_p20,
        PERCENTILE_CONT(0.40)
            WITHIN GROUP(ORDER BY monetary_observed_value) AS m_p40,
        PERCENTILE_CONT(0.60)
            WITHIN GROUP(ORDER BY monetary_observed_value) AS m_p60,
        PERCENTILE_CONT(0.80)
            WITHIN GROUP(ORDER BY monetary_observed_value) AS m_p80
    FROM portofolio_2.mv_customer_rfm_base
)
SELECT
    r.*,
    CASE
        WHEN r.recency_days <= t.r_p20 THEN 5
        WHEN r.recency_days <= t.r_p40 THEN 4
        WHEN r.recency_days <= t.r_p60 THEN 3
        WHEN r.recency_days <= t.r_p80 THEN 2
        ELSE 1
    END AS r_score,
    CASE
        WHEN r.frequency_purchase_sessions >= 6 THEN 5
        WHEN r.frequency_purchase_sessions >= 4 THEN 4
        WHEN r.frequency_purchase_sessions = 3 THEN 3
        WHEN r.frequency_purchase_sessions = 2 THEN 2
        ELSE 1
    END AS f_score,
    CASE
        WHEN r.monetary_observed_value >= t.m_p80 THEN 5
        WHEN r.monetary_observed_value >= t.m_p60 THEN 4
        WHEN r.monetary_observed_value >= t.m_p40 THEN 3
        WHEN r.monetary_observed_value >= t.m_p20 THEN 2
        ELSE 1
    END AS m_score
FROM portofolio_2.mv_customer_rfm_base r
CROSS JOIN thresholds t;

CREATE UNIQUE INDEX idx_customer_rfm_scored_user
ON portofolio_2.mv_customer_rfm_scored (user_id);

CREATE INDEX idx_customer_rfm_scored_scores
ON portofolio_2.mv_customer_rfm_scored (
    r_score,
    f_score,
    m_score);

ANALYZE portofolio_2.mv_customer_rfm_scored;

--7. Score validation
SELECT
    r_score,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*)/ SUM(COUNT(*)) OVER (),2) AS customer_share_pct
FROM portofolio_2.mv_customer_rfm_scored
GROUP BY 1
ORDER BY 1 DESC;

-- R-score distribution ≈ 20% per group.
SELECT
    f_score,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*)/ SUM(COUNT(*)) OVER (),2) AS customer_share_pct
FROM portofolio_2.mv_customer_rfm_scored
GROUP BY 1
ORDER BY 1 DESC;
--Observed:
--F1 = 78.27%
--F2 = 12.97%
--F3 =  4.34%
--F4 =  2.95%
--F5 =  1.47%

SELECT
    m_score,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*)/ SUM(COUNT(*)) OVER (),2) AS customer_share_pct
FROM portofolio_2.mv_customer_rfm_scored
GROUP BY m_score
ORDER BY m_score DESC;
/*
M-score distribution ≈ 20% per group.
Business-oriented RFM bands
Recency:
-Recent = R4–R5
-Mid    = R2–R3
-Stale  = R1
Frequency:
-One-Time       = F1
-Repeat         = F2–F3
-High Frequency = F4–F5
Monetary:
-Low Value  = M1
-Mid Value  = M2–M3
-High Value = M4–M5
*/

--9. Final RFM segmentation
CREATE MATERIALIZED VIEW
    portofolio_2.mv_customer_rfm_segment AS
WITH bands AS (
    SELECT
        *,
        CASE
            WHEN r_score >= 4 THEN 'Recent'
            WHEN r_score >= 2 THEN 'Mid'
            ELSE 'Stale'
        END AS recency_band,
        CASE
            WHEN f_score >= 4
                THEN 'High Frequency'
            WHEN f_score >= 2
                THEN 'Repeat'
            ELSE 'One-Time'
        END AS frequency_band,
        CASE
            WHEN m_score >= 4
                THEN 'High Value'
            WHEN m_score >= 2
                THEN 'Mid Value'
            ELSE 'Low Value'
        END AS monetary_band
    FROM portofolio_2.mv_customer_rfm_scored
)
SELECT
    *,
    CASE
        WHEN recency_band = 'Recent'
         AND frequency_band = 'High Frequency'
         AND monetary_band = 'High Value'
            THEN 'Champions'
        WHEN monetary_band = 'High Value'
         AND recency_band IN (
             'Recent',
             'Mid'
         )
         AND frequency_band IN (
             'Repeat',
             'High Frequency'
         )
            THEN 'Loyal High-Value'
        WHEN recency_band = 'Recent'
         AND frequency_band = 'One-Time'
         AND monetary_band = 'High Value'
            THEN 'Recent High-Value'
        WHEN recency_band = 'Mid'
         AND frequency_band = 'One-Time'
         AND monetary_band = 'High Value'
            THEN 'Cooling High-Value'
        WHEN recency_band = 'Recent'
            THEN 'Promising'
        WHEN recency_band = 'Mid'
            THEN 'Needs Attention'
        WHEN recency_band = 'Stale'
         AND monetary_band = 'High Value'
            THEN 'At Risk High-Value'
        ELSE 'Dormant Low/Mid Value'
    END AS rfm_segment
FROM bands;

CREATE UNIQUE INDEX idx_customer_rfm_segment_user
ON portofolio_2.mv_customer_rfm_segment (user_id);

CREATE INDEX idx_customer_rfm_segment_name
ON portofolio_2.mv_customer_rfm_segment (rfm_segment);

ANALYZE portofolio_2.mv_customer_rfm_segment;

--10. Final RFM segment summary
SELECT
    rfm_segment,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*)/ SUM(COUNT(*)) OVER (),2) AS customer_share_pct,
    ROUND(SUM(monetary_observed_value),2) AS observed_purchase_value,
    ROUND(100.0 * SUM(monetary_observed_value)/ SUM(SUM(monetary_observed_value)) OVER (),2) AS value_share_pct,
    ROUND(AVG(monetary_observed_value),2) AS avg_observed_value,
    ROUND(AVG(recency_days),2) AS avg_recency_days,
    ROUND(AVG(frequency_purchase_sessions),2) AS avg_purchase_sessions
FROM portofolio_2.mv_customer_rfm_segment
GROUP BY rfm_segment
ORDER BY observed_purchase_value DESC;
/*
-Loyal High-Value: 14,029 customers | 27.56% value
-Champions: 4,035 customers | 17.81% value
-Cooling High-Value: 10,541 customers | 12.86% value
-Recent High-Value: 8,790 customers | 10.93% value
-Needs Attention: 28,057 customers | 9.22% value
-At Risk High-Value: 6,824 customers | 9.12% value
-Promising: 23,742 customers | 7.79% value
-Dormant Low/Mid Value: 14,482 customers | 4.69% value

BUSINESS INTERPRETATION
-Champions + Loyal High-Value:
-16.35% of customers
-45.37% of historical Observed Purchase Value.
-Customer value is therefore materially concentrated.
-RFM labels are descriptive operational segments.
-They are NOT churn predictions or CLV forecasts.
*/
