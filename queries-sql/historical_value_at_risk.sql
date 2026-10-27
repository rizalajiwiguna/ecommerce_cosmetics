--1. Historical-value status
CREATE MATERIALIZED VIEW
    portofolio_2.mv_customer_historical_value_status AS
SELECT
    user_id,
    recency_days,
    frequency_purchase_sessions,
    monetary_observed_value,
    r_score,
    f_score,
    m_score,
    rfm_segment,
    CASE
        WHEN m_score >= 4
         AND r_score >= 4
            THEN 'Recent High-Value'
        WHEN m_score >= 4
         AND r_score IN (2, 3)
            THEN 'High-Value Watchlist'
        WHEN m_score >= 4
         AND r_score = 1
            THEN 'Historical Value at Risk'
        ELSE 'Other Customers'
    END AS historical_value_status,
    CASE
        WHEN f_score >= 4
            THEN 'High Frequency'
        WHEN f_score >= 2
            THEN 'Repeat'
        ELSE 'One-Time'
    END AS frequency_profile
FROM portofolio_2.mv_customer_rfm_segment;

CREATE UNIQUE INDEX idx_historical_value_status_user
ON portofolio_2.mv_customer_historical_value_status (
    user_id
);

CREATE INDEX idx_historical_value_status
ON portofolio_2.mv_customer_historical_value_status (
    historical_value_status
);

ANALYZE portofolio_2.mv_customer_historical_value_status;

--2. Historical value exposure
SELECT
    historical_value_status,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*)/ SUM(COUNT(*)) OVER (),2) AS customer_share_pct,
    ROUND(SUM(monetary_observed_value),2) AS historical_observed_value,
    ROUND(100.0 * SUM(monetary_observed_value)/ SUM(SUM(monetary_observed_value)) OVER (),2) AS historical_value_share_pct,
    ROUND(AVG(monetary_observed_value),2) AS avg_historical_value,
    ROUND(AVG(recency_days),2) AS avg_recency_days,
    ROUND(AVG(frequency_purchase_sessions),2) AS avg_purchase_sessions
FROM portofolio_2.mv_customer_historical_value_status
GROUP BY historical_value_status
ORDER BY historical_observed_value DESC;

/*
Observed:
Recent High-Value
20,734 customers
43.89% historical value

High-Value Watchlist
16,661 customers
25.28% historical value

Historical Value at Risk
6,824 customers
9.12% historical value

Other Customers
-66,281 customers
-21.71% historical value
*/

--3. Historical Value at Risk by frequency profile
SELECT
    frequency_profile,
    COUNT(*) AS customers,
    ROUND(100.0 * COUNT(*)/ SUM(COUNT(*)) OVER (),2) AS customer_share_within_at_risk,
    ROUND(SUM(monetary_observed_value),2) AS historical_observed_value,
    ROUND(100.0 * SUM(monetary_observed_value)/ SUM(SUM(monetary_observed_value)) OVER (),2) AS value_share_within_at_risk,
    ROUND(AVG(monetary_observed_value),2) AS avg_historical_value,
    ROUND(AVG(frequency_purchase_sessions),2) AS avg_purchase_sessions,
    ROUND(AVG(recency_days),2) AS avg_recency_days
FROM portofolio_2.mv_customer_historical_value_status
WHERE historical_value_status = 'Historical Value at Risk'
GROUP BY frequency_profile
ORDER BY historical_observed_value DESC;
/*
Observed:
One-Time:
5,732 customers
76.66% of at-risk historical value

Repeat:
1,049 customers
21.72% of at-risk historical value

High Frequency:
43 customers
1.62% of at-risk historical value

Repeat + High Frequency:
16.00% of at-risk customers
23.34% of at-risk historical value
*/

--4. High-Value Watchlist by frequency profile
SELECT
    frequency_profile,
    COUNT(*) AS customers,
    ROUND(SUM(monetary_observed_value),2) AS historical_observed_value,
    ROUND(AVG(monetary_observed_value),2) AS avg_historical_value,
    ROUND(AVG(recency_days),2) AS avg_recency_days,
    ROUND(AVG(frequency_purchase_sessions),2) AS avg_purchase_sessions
FROM portofolio_2.mv_customer_historical_value_status
WHERE historical_value_status = 'High-Value Watchlist'
GROUP BY frequency_profile
ORDER BY historical_observed_value DESC;
/*
Observed:
One-Time:
10,541 customers
816,825.38 historical value

Repeat:
5,349 customers
612,273.35 historical value

High Frequency:
771 customers
176,408.01 historical value

Repeat + High Frequency account for approximately
49.12% of Watchlist historical value.
*/

/*
BUSINESS INTERPRETATION
High-Value Watchlist + Historical Value at Risk:
-21.25% of purchasing customers
-34.40% of historical Observed Purchase Value.
    
Business distinction:
-Watchlist → preventive retention opportunity.
-At Risk → reactivation opportunity.

Customers with prior repeat/high-frequency behavior provide stronger historical engagement evidence, but the analysis does NOT predict who is most likely to return.
*/
