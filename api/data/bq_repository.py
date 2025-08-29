import os
from typing import Dict, List
from google.cloud import bigquery

# Environment variables with defaults
PROJECT_ID = os.getenv("BQ_PROJECT", "n8n-ads-spend")
DATASET    = os.getenv("BQ_DATASET", "ads_warehouse")
TABLE      = os.getenv("BQ_TABLE", "ads_spend_raw")
TABLE_FQN  = f"`{PROJECT_ID}.{DATASET}.{TABLE}`"

class BigQueryRepository:
    def __init__(self, client: bigquery.Client | None = None):
        # Reuse an injected client or create a new one
        self.client = client or bigquery.Client()

    def compare_periods(
        self, first_start: str, first_end: str, second_start: str, second_end: str
    ) -> List[Dict]:
        """
        Returns two rows (period in ['first','second']) with aggregated and derived metrics.

        Query breakdown:
        - base: daily aggregation (spend, conversions, revenue)
        - labelled: tag each day as 'first' or 'second' depending on the date range
        - agg: roll up to the period level
        - final SELECT: calculate CAC (spend/conversions) and ROAS (revenue/spend)
        """
        sql = f"""
        WITH base AS (
          SELECT DATE(date) AS dt,
                 SUM(spend)       AS spend,
                 SUM(conversions) AS conversions,
                 SUM(revenue)     AS revenue
          FROM {TABLE_FQN}
          WHERE DATE(date) BETWEEN @first_start AND @second_end
          GROUP BY dt
        ),
        labelled AS (
          SELECT
            dt, spend, conversions, revenue,
            CASE
              WHEN dt BETWEEN @first_start AND @first_end THEN 'first'
              WHEN dt BETWEEN @second_start AND @second_end THEN 'second'
            END AS period
          FROM base
        ),
        agg AS (
          SELECT
            period,
            SUM(spend)       AS spend,
            SUM(conversions) AS conversions,
            SUM(revenue)     AS revenue
          FROM labelled
          WHERE period IS NOT NULL
          GROUP BY period
        )
        SELECT
          period,
          spend,
          conversions,
          revenue,
          SAFE_DIVIDE(spend, NULLIF(conversions,0)) AS CAC,
          SAFE_DIVIDE(revenue, NULLIF(spend,0))     AS ROAS
        FROM agg
        """

        # Bind parameters safely
        job_config = bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("first_start",  "DATE", first_start),
                bigquery.ScalarQueryParameter("first_end",    "DATE", first_end),
                bigquery.ScalarQueryParameter("second_start", "DATE", second_start),
                bigquery.ScalarQueryParameter("second_end",   "DATE", second_end),
            ]
        )

        rows = list(self.client.query(sql, job_config=job_config).result())
        return [dict(r) for r in rows]
