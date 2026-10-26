/*
A. Purpose:
-Evaluate data quality issues that may affect downstream
-analytical interpretation.

B. Key areas:
1. Missing values
2. Session integrity
3. Category and brand consistency
4. Price anomalies
5. Exact repeated rows
6. Sensitivity of monetary conclusions to repeated rows
*/

--1. Missing-value profile
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER(WHERE event_time IS NULL) AS event_time_nulls,
    COUNT(*) FILTER(WHERE event_type IS NULL) AS event_type_nulls,
    COUNT(*) FILTER(WHERE product_id IS NULL) AS product_id_nulls,
    COUNT(*) FILTER(WHERE category_id IS NULL) AS category_id_nulls,
    COUNT(*) FILTER(WHERE category_code IS NULL) AS category_code_nulls,
    COUNT(*) FILTER(WHERE brand IS NULL) AS brand_nulls,
    COUNT(*) FILTER(WHERE price IS NULL) AS price_nulls,
    COUNT(*) FILTER(WHERE user_id IS NULL) AS user_id_nulls,
    COUNT(*) FILTER(WHERE user_session IS NULL) AS user_session_nulls
FROM portofolio_2.events;
/*
result key findings:
-category_code NULL = 20,339,246 (98.29%)
-brand NULL         = 8,757,117  (42.32%)
-user_session NULL  = 4,598      (~0.02%)
-Other core fields contain no missing values.
*/

--2 Missing source session by event type
SELECT
    event_type,
    COUNT(*) AS null_session_events
FROM portofolio_2.events
WHERE user_session IS NULL
GROUP BY 1
ORDER BY 2 DESC;
/*result:
cart              = 3,776
-remove_from_cart  =   791
-view              =    31
-purchase          =     0
*/

--3. Impact of missing source sessions
SELECT
    COUNT(*) AS affected_events,
    COUNT(DISTINCT user_id) AS affected_users,
    COUNT(DISTINCT product_id) AS affected_products
FROM portofolio_2.events
WHERE user_session IS NULL;

/*
Observed:
-affected_events   = 4,598
-affected_users    = 1,533
-affected_products = 2,002
*/

--4. Multi-user source sessions
WITH multi_user_sessions AS (
    SELECT
        user_session
    FROM portofolio_2.events
    WHERE user_session IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT user_id) > 1
)
SELECT
    COUNT(*) AS multi_user_sessions
FROM multi_user_sessions;
--result:
--272 source sessions

--5. Impact of multi-user source sessions
WITH multi_user_sessions AS (
    SELECT
        user_session
    FROM portofolio_2.events
    WHERE user_session IS NOT NULL
    GROUP BY 1
    HAVING COUNT(DISTINCT user_id) > 1
)
SELECT
    COUNT(*) AS affected_events,
    COUNT(DISTINCT e.user_session) AS affected_sessions,
    COUNT(DISTINCT e.user_id) AS affected_users,
    COUNT(*) FILTER(WHERE e.event_type = 'purchase') AS affected_purchase_events
FROM portofolio_2.events e
JOIN multi_user_sessions m
    ON e.user_session = m.user_session;
/*
result:
-affected_events          = 1,985
-affected_sessions        = 272
-affected_users           = 591
-affected_purchase_events = 109
*/

--6. Category-code coverage
SELECT
    COUNT(DISTINCT category_id)
        FILTER(WHERE category_code IS NOT NULL) AS category_ids_with_code,
    COUNT(DISTINCT category_id)
    FILTER(WHERE category_code IS NULL) AS category_ids_in_null_code_rows
FROM portofolio_2.events;
--result :
--category_ids_with_code         = 18
--category_ids_in_null_code_rows = 507

--7. Category-code consistency
WITH category_mapping AS (
    SELECT
        category_id,
        COUNT(DISTINCT category_code)FILTER(WHERE category_code IS NOT NULL) AS distinct_category_codes
    FROM portofolio_2.events
    GROUP BY 1
)
SELECT
    COUNT(*)FILTER(WHERE distinct_category_codes > 1) AS category_ids_with_multiple_codes
FROM category_mapping;
/*
result:
0

decision:
-category_code is too sparse to serve as the primary
-category dimension. category_id remains the main category
-field; category_code is supplementary only.
*/

--8. Brand coverage and consistency
WITH product_brand_profile AS (
    SELECT
        product_id,
        COUNT(DISTINCT brand)FILTER(WHERE brand IS NOT NULL) AS distinct_known_brands
    FROM portofolio_2.events
    GROUP BY 1
)
SELECT
    COUNT(*)FILTER(WHERE distinct_known_brands >= 1) AS products_with_known_brand,
    COUNT(*)FILTER(WHERE distinct_known_brands = 0) AS products_never_branded,
    COUNT(*)FILTER(WHERE distinct_known_brands > 1) AS products_with_multiple_brands
FROM product_brand_profile;
/*
Observed:
-products_with_known_brand     = 31,098
-products_never_branded        = 23,473
-products_with_multiple_brands = 24

Decision:
-Brand is retained as an event-time attribute.
-No forced product-level brand mapping is created.
*/

--9. Product tocategory consistency
WITH product_category_profile AS (
    SELECT
        product_id,
        COUNT(DISTINCT category_id) AS distinct_category_ids
    FROM portofolio_2.events
    GROUP BY 1
)
SELECT
    COUNT(*)FILTER(WHERE distinct_category_ids > 1) AS products_with_multiple_categories
FROM product_category_profile;
--result:
--1,619 products (~2.97%)

--decision:
--category_id is treated as an event-time attribute rather
--than forcing one static category per product.

--10. Overall price diagnostics
SELECT
    MIN(price) AS min_price,
    MAX(price) AS max_price,
    ROUND(AVG(price), 2) AS avg_price,
    COUNT(*)FILTER(WHERE price < 0) AS negative_price_events,
    COUNT(*)FILTER(WHERE price = 0) AS zero_price_events
FROM portofolio_2.events;
/*
result:
-min_price             = -79.37
-max_price             = 327.78
-avg_price             = 8.53
-negative_price_events = 131
-zero_price_events     = 104,157
*/

--11. Purchase price diagnostics
SELECT
    MIN(price) AS min_purchase_price,
    MAX(price) AS max_purchase_price,
    ROUND(AVG(price), 2) AS avg_purchase_price,
    COUNT(*)FILTER(WHERE price < 0) AS negative_purchase_events,
    COUNT(*)FILTER(WHERE price = 0) AS zero_purchase_events
FROM portofolio_2.events
WHERE event_type = 'purchase';
/*
result:
-min_purchase_price       = -79.37
-max_purchase_price       = 327.78
-avg_purchase_price       = 4.93
-negative_purchase_events = 126
-zero_purchase_events     = 1
*/

--12. Positive purchase-price distribution
SELECT
    ROUND(PERCENTILE_CONT(0.01)WITHIN GROUP (ORDER BY price)::numeric,2) AS p01,
    ROUND(PERCENTILE_CONT(0.25)WITHIN GROUP (ORDER BY price)::numeric,2) AS p25,
    ROUND(PERCENTILE_CONT(0.50)WITHIN GROUP (ORDER BY price)::numeric,2) AS median,
    ROUND(PERCENTILE_CONT(0.75)WITHIN GROUP (ORDER BY price)::numeric,2) AS p75,
    ROUND(PERCENTILE_CONT(0.95)WITHIN GROUP (ORDER BY price)::numeric,2) AS p95,
    ROUND(PERCENTILE_CONT(0.99)WITHIN GROUP (ORDER BY price)::numeric,2) AS p99,
    MAX(price) AS max_price
FROM portofolio_2.events
WHERE event_type = 'purchase'
  AND price > 0;
/*
result:
-p01    = 0.32
-p25    = 1.59
-median = 3.00
-p75    = 5.40
-p95    = 14.27
-p99    = 33.32
-max    = 327.78
*/

--13. Non-positive purchase-price profile
SELECT
    product_id,
    price,
    COUNT(*) AS purchase_events,
    MIN(event_time AT TIME ZONE 'UTC') AS first_observed_utc,
    MAX(event_time AT TIME ZONE 'UTC') AS last_observed_utc
FROM portofolio_2.events
WHERE event_type = 'purchase'
  AND price <= 0
GROUP BY
    1,2
ORDER BY
    2,1;

/*
result:
A purchase event remains a behavioral purchase even when
-price <= 0.

However, price <= 0 is excluded from monetary-value
-calculations because the dataset does not provide enough
-evidence to interpret these values as valid sales value.
-Negative prices are NOT automatically labelled refunds.
*/

--14. Exact repeated analytical rows
--Exact equality across every available source column does
--not prove accidental duplication because no event_id or
--quantity field exists.
WITH repeated_groups AS (
    SELECT
        event_time,
        event_type,
        product_id,
        category_id,
        category_code,
        brand,
        price,
        user_id,
        user_session,
        COUNT(*) AS occurrence_count
    FROM portofolio_2.events
    GROUP BY 1,2,3,4,5,6,7,8,9
    HAVING COUNT(*) > 1
)
SELECT
    COUNT(*) AS repeated_groups,
    SUM(occurrence_count) AS rows_in_repeated_groups,
    SUM(occurrence_count - 1) AS excess_repeated_rows
FROM repeated_groups;
--result:
--repeated_groups         = 1,045,762
--rows_in_repeated_groups = 2,154,860
--excess_repeated_rows    = 1,109,098 (~5.36%)

--15. Repeated rows by event type
WITH repeated_groups AS (
    SELECT
        event_time,
        event_type,
        product_id,
        category_id,
        category_code,
        brand,
        price,
        user_id,
        user_session,
        COUNT(*) AS occurrence_count
    FROM portofolio_2.events
    GROUP BY 1,2,3,4,5,6,7,8,9
    HAVING COUNT(*) > 1
)
SELECT
    event_type,
    COUNT(*) AS repeated_groups,
    SUM(occurrence_count) AS rows_in_repeated_groups,
    SUM(occurrence_count - 1) AS excess_repeated_rows
FROM repeated_groups
GROUP BY 1
ORDER BY 4 DESC;

--result excess repeated rows:
--remove_from_cart = 991,820
--cart             = 115,342
--view             =   1,031
--purchase         =     905

--16. Purchase-value sensitivity to exact deduplication
WITH raw_purchase AS (
    SELECT
        COUNT(*) AS purchase_events,
        SUM(price) AS observed_value
    FROM portofolio_2.events
    WHERE event_type = 'purchase'
      AND price > 0
),
deduplicated_purchase AS (
    SELECT
        COUNT(*) AS purchase_events,
        SUM(price) AS observed_value
    FROM (
        SELECT DISTINCT
            event_time,
            event_type,
            product_id,
            category_id,
            category_code,
            brand,
            price,
            user_id,
            user_session
        FROM portofolio_2.events
        WHERE event_type = 'purchase'
          AND price > 0
    ) d
)
SELECT
    r.purchase_events AS raw_purchase_events,
    d.purchase_events AS dedup_purchase_events,
    r.purchase_events - d.purchase_events AS event_difference,
    ROUND(r.observed_value,2) AS raw_observed_value,
    ROUND(d.observed_value,2) AS dedup_observed_value,
    ROUND(r.observed_value - d.observed_value,2) AS observed_value_difference,
    ROUND(100.0 * (r.observed_value - d.observed_value)/ NULLIF(r.observed_value, 0), 4) AS observed_value_difference_pct
FROM raw_purchase r
CROSS JOIN deduplicated_purchase d;
/*
result:
-raw_purchase_events            = 1,286,880
-dedup_purchase_events          = 1,285,982
-event_difference               = 898
-raw_observed_value             = 6,351,830.29
-dedup_observed_value           = 6,348,267.70
-observed_value_difference      = 3,562.59
-observed_value_difference_pct  = 0.0561%

Final decision:
-Exact repeated rows are preserved.

-Their semantics cannot be resolved without event_id or
-quantity, while deduplication changes positive-purchase
-observed value by only ~0.0561%.
