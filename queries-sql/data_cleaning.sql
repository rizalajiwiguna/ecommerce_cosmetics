/*
Purpose:
-Apply defensible cleaning and analytical validity rules
-while preserving the raw source table unchanged.

Cleaning strategy:
1. Preserve portofolio_2.events as an immutable raw layer.
2. Identify source sessions that belong to exactly one user. Multi-user sessions are excluded only from session-based analysis.
3. Retain behavioral purchase events even when price <= 0, but include only positive-price purchases in monetarycalculations.
4. Do not impute missing brand or category_code.
5. Do not deduplicate exact repeated rows because theirsemantics cannot be determined from the available fields.
6. Standardize analytical timestamps to UTC.
*/

-- 1. Valid source session
CREATE MATERIALIZED VIEW
    portofolio_2.mv_valid_sessions AS

SELECT
    user_session,
    MIN(user_id) AS user_id
FROM portofolio_2.events
WHERE user_session IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT user_id) = 1;

CREATE UNIQUE INDEX idx_valid_sessions_session
ON portofolio_2.mv_valid_sessions(user_session);

ANALYZE portofolio_2.mv_valid_sessions;

--2. Validate valid-session population
SELECT
    COUNT(*) AS valid_source_sessions
FROM portofolio_2.mv_valid_sessions;
/*
result : 
4,535,669

Reconciliation:
4,535,941 total non-null source sessions
-272 multi-user sessions = 4,535,669 valid source sessions
*/

--3. Clean analytical event view
-- Raw rows are preserved and Quality issues are represented using explicit flags.

CREATE OR REPLACE VIEW
    portofolio_2.vw_events_clean AS
SELECT
    e.event_time,
    e.event_time AT TIME ZONE 'UTC' AS event_time_utc,
    e.event_type,
    e.product_id,
    e.category_id,
    e.category_code,
    e.brand,
    e.price,
    e.user_id,
    e.user_session,
    CASE
        WHEN vs.user_session IS NOT NULL
            THEN TRUE
        ELSE FALSE
    END AS is_valid_session,
    CASE
        WHEN e.event_type = 'purchase'
         AND e.price > 0
            THEN TRUE
        ELSE FALSE
    END AS is_valid_monetary_purchase,
    CASE
        WHEN e.event_type = 'purchase'
         AND e.price > 0
            THEN e.price
        ELSE 0
    END AS observed_purchase_value,
    CASE
        WHEN e.brand IS NOT NULL
            THEN TRUE
        ELSE FALSE
    END AS has_brand,
    CASE
        WHEN e.category_code IS NOT NULL
            THEN TRUE
        ELSE FALSE
    END AS has_category_code
FROM portofolio_2.events e
LEFT JOIN portofolio_2.mv_valid_sessions vs
    ON e.user_session = vs.user_session
   AND e.user_id = vs.user_id;

--4. Cleaning-layer reconciliation
SELECT
    COUNT(*) AS total_events,
    COUNT(*)FILTER(WHERE is_valid_session) AS events_in_valid_sessions,
    COUNT(*)FILTER(WHERE NOT is_valid_session) AS events_outside_valid_sessions,
    COUNT(*)FILTER(WHERE is_valid_monetary_purchase) AS valid_monetary_purchase_events,
    ROUND(SUM(observed_purchase_value),2) AS observed_purchase_value
FROM portofolio_2.vw_events_clean;
/*
result:
-total_events                    = 20,692,840
-events_in_valid_sessions        = 20,686,257
-events_outside_valid_sessions   = 6,583
-valid_monetary_purchase_events  = 1,286,880
-observed_purchase_value         = 6,351,830.29
*/

--5. Reconcile excluded session-based events
SELECT
    COUNT(*)FILTER(WHERE user_session IS NULL) AS null_session_events,
    COUNT(*)FILTER(WHERE user_session IS NOT NULL AND NOT is_valid_session) AS invalid_multi_user_session_events,
    COUNT(*) FILTER(WHERE NOT is_valid_session) AS total_events_outside_valid_sessions
FROM portofolio_2.vw_events_clean;

--result:
--null_session_events                = 4,598
-- invalid_multi_user_session_events  = 1,985
-- total                              = 6,583
