WITH base AS (
  --CTE 1: base - Aggregate daily spend and conversions
  --This is the foundational data layer where we roll up metrics to date level
  SELECT
    DATE(date) AS dt,  --Ensure consistent date format, time is truncated
    SUM(spend) AS spend,
    SUM(conversions) AS conv
  FROM `n8n-ads-spend.ads_warehouse.ads_spend_raw`
  WHERE DATE(date) BETWEEN '2025-05-01' AND '2025-06-30'
  GROUP BY dt  -- Daily aggregation level
),
agg AS (
  -- CTE 2: agg - Roll up daily data to period level (prev vs last)
  -- This classifies days into comparison groups and aggregates metrics
  SELECT
    -- FIXED LOGIC: Categorize dates into comparison periods
    -- Uses hardcoded dates because CURRENT_DATE() cannot be trusted in this dataset
    CASE WHEN dt >= '2025-06-01' THEN 'last_period'  -- June 2025
         ELSE 'prev_period' END AS period,           -- May 2025
    SUM(spend) AS spend,        -- Total spend for period
    SUM(conv) AS conv           -- Total conversions for period
  FROM base
  GROUP BY period  -- Group by our manually defined periods
),
-- CTE 3: periods - Ensure both comparison periods are always represented
-- This prevents NULL results if one period has no data
periods AS (
  SELECT 'last_period' AS period 
  UNION ALL 
  SELECT 'prev_period'
),
filled AS (
  -- CTE 4: filled - Calculate derived metrics with safe division
  -- Left join ensures we get both periods even with missing data
  SELECT
    p.period,
    IFNULL(a.spend, 0) AS spend,           -- Handle missing data as 0
    IFNULL(a.conv, 0) AS conv,             -- Handle missing data as 0
    IFNULL(a.conv, 0) * 100 AS revenue,    -- Revenue assumption: $100 per conversion
    -- CAC calculation: Cost per Acquisition with division protection
    SAFE_DIVIDE(IFNULL(a.spend, 0), NULLIF(IFNULL(a.conv, 0), 0)) AS CAC,
    -- ROAS calculation: Return on Ad Spend with division protection
    SAFE_DIVIDE(IFNULL(a.conv, 0) * 100, NULLIF(IFNULL(a.spend, 0), 0)) AS ROAS
  FROM periods p
  LEFT JOIN agg a USING (period)  -- Preserve all periods from CTE
),
pivoted AS (
  -- CTE 5: pivoted - Transform period-based rows to columnar format
  -- This restructures the data for easier comparison in final SELECT
  SELECT
    -- Extract each metric into separate columns for comparison
    MAX(IF(period='last_period', spend, NULL)) AS spend_last,
    MAX(IF(period='prev_period', spend, NULL)) AS spend_prev,
    MAX(IF(period='last_period', conv, NULL)) AS conv_last,
    MAX(IF(period='prev_period', conv, NULL)) AS conv_prev,
    MAX(IF(period='last_period', revenue, NULL)) AS revenue_last,
    MAX(IF(period='prev_period', revenue, NULL)) AS revenue_prev,
    MAX(IF(period='last_period', CAC, NULL)) AS CAC_last,
    MAX(IF(period='prev_period', CAC, NULL)) AS CAC_prev,
    MAX(IF(period='last_period', ROAS, NULL)) AS ROAS_last,
    MAX(IF(period='prev_period', ROAS, NULL)) AS ROAS_prev
  FROM filled
)
-- FINAL SELECT: Calculate absolute values and percentage changes
-- Returns single row with complete period comparison
SELECT
  -- Absolute Values (raw metrics)
  spend_last,
  spend_prev,
  conv_last,
  conv_prev,
  revenue_last,
  revenue_prev,
  ROUND(CAC_last, 2) AS CAC_last,      -- Rounded for readability
  ROUND(CAC_prev, 2) AS CAC_prev,      -- Rounded for readability
  ROUND(ROAS_last, 2) AS ROAS_last,    -- Rounded for readability
  ROUND(ROAS_prev, 2) AS ROAS_prev,    -- Rounded for readability
  -- Percentage Deltas (period-over-period change)
  -- All calculations use SAFE_DIVIDE to handle division by zero
  ROUND(SAFE_DIVIDE(spend_last - spend_prev, NULLIF(spend_prev, 0)) * 100, 2) AS spend_delta_pct,
  ROUND(SAFE_DIVIDE(conv_last - conv_prev, NULLIF(conv_prev, 0)) * 100, 2) AS conversions_delta_pct,
  ROUND(SAFE_DIVIDE(revenue_last - revenue_prev, NULLIF(revenue_prev, 0)) * 100, 2) AS revenue_delta_pct,
  ROUND(SAFE_DIVIDE(CAC_last - CAC_prev, NULLIF(CAC_prev, 0)) * 100, 2) AS CAC_delta_pct,
  ROUND(SAFE_DIVIDE(ROAS_last - ROAS_prev, NULLIF(ROAS_prev, 0)) * 100, 2) AS ROAS_delta_pct
FROM pivoted;