/*E-COMMERCE COSMETICS — CUSTOMER JOURNEY, CONVERSION & RETENTION ANALYTICS
2. DATA UNDERSTANDING
A. Purpose:
-Profile the raw dataset before any cleaning or analytical
-transformation is applied.

B. This stage answers:
-How large is the dataset?
-What time period is covered?
-What behavioral events exist?
-How many users, sessions, products, and categories exist?
*/ 

--1. Dataset size and observation period
SELECT
    COUNT(*) AS total_events,
    MIN(event_time AT TIME ZONE 'UTC') AS first_event_utc,
    MAX(event_time AT TIME ZONE 'UTC') AS last_event_utc
FROM portofolio_2.events;
-- result:
-- total_events = 20,692,840
-- Full source window covers October 2019 — February 2020.

--2. Event-type distribution
SELECT 
    event_type,
    COUNT(*) AS events,
    ROUND(100.0 * COUNT(*)/SUM(COUNT(*))OVER(), 2) AS event_share_pct
FROM portofolio_2.events
GROUP BY 1
ORDER BY 2 DESC;
-- result:
-- view              = 9,657,821
-- cart              = 5,768,333
-- remove_from_cart  = 3,979,679
-- purchase          = 1,287,007

--3. Validate event-type domain
SELECT
    COUNT(*) AS invalid_event_types
FROM portofolio_2.events
WHERE event_type NOT IN (
    'view',
    'cart',
    'remove_from_cart',
    'purchase'
)
OR event_type IS NULL;
--result:
--invalid_event_types = 0

--4. Monthly event coverage
SELECT
    DATE_TRUNC('month',event_time AT TIME ZONE 'UTC')::date AS event_month,
    COUNT(*) AS events
FROM portofolio_2.events
GROUP BY 1
ORDER BY 1;

--Observed:
--2019-10 = 4,102,283
--2019-11 = 4,635,837
--2019-12 = 3,533,286
--2020-01 = 4,264,752
--2020-02 = 4,156,682

-- 02.5 Core cardinality
SELECT
    COUNT(DISTINCT user_id) AS unique_users,
    COUNT(DISTINCT user_session) AS unique_source_sessions,
    COUNT(DISTINCT product_id) AS unique_products,
    COUNT(DISTINCT category_id) AS unique_category_ids,
    COUNT(DISTINCT category_code) AS unique_category_codes,
    COUNT(DISTINCT brand) AS unique_brands
FROM portofolio_2.events;

--result:
--unique_users           = 1,639,358
--unique_source_sessions = 4,535,941
--unique_products        = 54,571
--unique_category_ids    = 525
--unique_category_codes  = 12
--unique_brands          = 273
