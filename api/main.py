import os
from datetime import date, datetime, timedelta
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from google.cloud import bigquery

# Initialize FastAPI app
app = FastAPI(title="Metrics API", version="1.0.0")

# Environment variables (set in Cloud Run)
PROJECT_ID = os.getenv("PROJECT_ID")                  # GCP project ID
DATASET    = os.getenv("BQ_DATASET", "ads_warehouse") # BigQuery dataset
TABLE      = os.getenv("BQ_TABLE", "ads_spend_raw")   # BigQuery table
API_KEY    = os.getenv("API_KEY")                     # Simple header auth

# BigQuery client using Application Default Credentials
client = bigquery.Client(project=PROJECT_ID)

# SQL template: calculates CAC and ROAS for last 30 days vs previous 30 days
SQL = f"""
WITH base AS (
  SELECT DATE(date) AS d, spend, conversions
  FROM `{PROJECT_ID}.{DATASET}.{TABLE}`
  WHERE DATE(date) BETWEEN @prevStart AND @end
),
win AS (
  SELECT
    SUM(CASE WHEN d BETWEEN @start AND @end THEN spend ELSE 0 END) AS spend_l30,
    SUM(CASE WHEN d BETWEEN @start AND @end THEN conversions ELSE 0 END) AS conv_l30,
    SUM(CASE WHEN d BETWEEN @prevStart AND @prevEnd THEN spend ELSE 0 END) AS spend_p30,
    SUM(CASE WHEN d BETWEEN @prevStart AND @prevEnd THEN conversions ELSE 0 END) AS conv_p30
  FROM base
)
SELECT
  spend_l30, conv_l30,
  SAFE_DIVIDE(spend_l30, NULLIF(conv_l30,0)) AS cac_l30,
  SAFE_DIVIDE((conv_l30 * 100), NULLIF(spend_l30,0)) AS roas_l30,
  spend_p30, conv_p30,
  SAFE_DIVIDE(spend_p30, NULLIF(conv_p30,0)) AS cac_p30,
  SAFE_DIVIDE((conv_p30 * 100), NULLIF(spend_p30,0)) AS roas_p30,
  SAFE_DIVIDE(cac_l30 - cac_p30, NULLIF(cac_p30,0)) AS cac_delta_pct,
  SAFE_DIVIDE(roas_l30 - roas_p30, NULLIF(roas_p30,0)) AS roas_delta_pct
"""

# Helper to parse YYYY-MM-DD into Python date
def _parse_date(s: str) -> date:
    return datetime.strptime(s, "%Y-%m-%d").date()

@app.get("/healthz")
def healthz():
    """Simple health check endpoint for Cloud Run monitoring"""
    return {"status": "ok"}

@app.get("/metrics")
def metrics(request: Request, start: str | None = None, end: str | None = None):
    """
    Metrics endpoint:
    - Query BigQuery to compute CAC and ROAS.
    - Accepts optional ?start=YYYY-MM-DD&end=YYYY-MM-DD query params.
    - Defaults to "last 30 days until today".
    - Compares against the previous 30-day period.
    """

    # Header-based API key authentication
    key = request.headers.get("x-api-key")
    if API_KEY and key != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")

    # Default dates: last 30 days until today
    today = date.today()
    end_d = _parse_date(end) if end else today
    start_d = _parse_date(start) if start else (end_d - timedelta(days=30))

    # Previous 30-day window
    prev_end = start_d - timedelta(days=1)
    prev_start = prev_end - timedelta(days=30)

    # Prepare query job with parameters
    job_config = bigquery.QueryJobConfig(
        query_parameters=[
            bigquery.ScalarQueryParameter("start", "DATE", start_d.isoformat()),
            bigquery.ScalarQueryParameter("end", "DATE", end_d.isoformat()),
            bigquery.ScalarQueryParameter("prevStart", "DATE", prev_start.isoformat()),
            bigquery.ScalarQueryParameter("prevEnd", "DATE", prev_end.isoformat()),
        ]
    )

    # Run query
    rows = list(client.query(SQL, job_config=job_config).result())
    if not rows:
        return JSONResponse({"error": "no_data"}, status_code=200)

    r = rows[0]

    # Build JSON response
    payload = {
        "range": {"start": start_d.isoformat(), "end": end_d.isoformat()},
        "prev_range": {"start": prev_start.isoformat(), "end": prev_end.isoformat()},
        "metrics": {
            "l30": {  # last 30 days
                "spend": float(r["spend_l30"] or 0),
                "conversions": int(r["conv_l30"] or 0),
                "cac": float(r["cac_l30"] or 0),
                "roas": float(r["roas_l30"] or 0),
            },
            "p30": {  # previous 30 days
                "spend": float(r["spend_p30"] or 0),
                "conversions": int(r["conv_p30"] or 0),
                "cac": float(r["cac_p30"] or 0),
                "roas": float(r["roas_p30"] or 0),
            },
            "deltas_pct": {  # percentage deltas
                "cac": float(r["cac_delta_pct"] or 0),
                "roas": float(r["roas_delta_pct"] or 0),
            },
        },
    }
    return JSONResponse(payload)
