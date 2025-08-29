# api/main.py
from datetime import datetime
from fastapi import FastAPI, HTTPException, Query
import logging
import os
import subprocess
from pathlib import Path
import requests

# ------------ App & Logging ------------
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
app = FastAPI(title="metrics-api")

# ------------ n8n ------------
# Test URL; when workflow is active, change to /webhook/...
N8N_WEBHOOK_URL = "http://34.171.79.204/webhook-test/d788d010-a7da-4e1d-ad89-addc572535f6"

# ------------ BigQuery config ------------
PROJECT_ID = os.getenv("PROJECT_ID", "n8n-ads-spend")
DATASET    = os.getenv("BQ_DATASET", "ads_warehouse")
TABLE      = os.getenv("BQ_TABLE", "ads_spend_raw")
LOCATION   = os.getenv("LOCATION", "US")  # IMPORTANT: region of your dataset (e.g., US, EU)
BQ_QUERY_URL = f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT_ID}/queries"
METADATA_TOKEN_URL = "http://metadata/computeMetadata/v1/instance/service-accounts/default/token"

# ------------ Auth helpers ------------
def _metadata_token_available() -> bool:
    try:
        r = requests.get(METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}, timeout=1.5)
        return r.status_code == 200
    except requests.RequestException:
        return False

def get_access_token() -> str:
    """
    Order:
      1) Metadata server (Cloud Run / GCE)
      2) Local dev: gcloud auth print-access-token
      3) If SA JSON is present, suggest using google-auth (we keep REST sample minimal)
    """
    if _metadata_token_available():
        try:
            r = requests.get(METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}, timeout=3)
            r.raise_for_status()
            return r.json()["access_token"]
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Metadata token error: {e}")

    try:
        token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True, timeout=5).strip()
        if token:
            return token
    except Exception:
        pass

    cred_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "")
    if cred_path and Path(cred_path).exists():
        raise HTTPException(
            status_code=500,
            detail=("GOOGLE_APPLICATION_CREDENTIALS detected. This sample uses REST with metadata/gcloud tokens. "
                    "Either run on Cloud Run/VM or switch to google-auth libraries for SA JSON."))
    raise HTTPException(status_code=500, detail="No access token available (metadata & gcloud both unavailable).")

# ------------ BigQuery helper ------------
def run_bq_query(sql: str, timeout_sec: int = 30) -> dict:
    """
    Run a synchronous BigQuery query (Jobs: query). Adds 'location' to avoid region errors.
    """
    token = get_access_token()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    body = {
        "query": sql,
        "useLegacySql": False,
        "location": LOCATION,  # many errors are caused by missing location
    }
    logging.info("BQ Query (location=%s): %s", LOCATION, " ".join(sql.split()))
    try:
        resp = requests.post(BQ_QUERY_URL, headers=headers, json=body, timeout=timeout_sec)
        if resp.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"BigQuery HTTP {resp.status_code}: {resp.text[:1000]}")
        data = resp.json()
        # If BigQuery returns an error payload even with 200 (rare), surface it:
        if "error" in data:
            raise HTTPException(status_code=502, detail=f"BigQuery error payload: {data['error']}")
        return data
    except requests.RequestException as e:
        raise HTTPException(status_code=502, detail=f"BigQuery request failed: {e}")

# ------------ Basic routes ------------
@app.get("/")
def root():
    return {"ok": True, "service": "metrics-api"}

@app.get("/health")
def health():
    return {"status": "ok"}

# ------------ n8n trigger (GET with params) ------------
@app.get("/trigger-n8n")
def trigger_n8n(insertId: str = Query(...), amount: float = Query(...)):
    params = {"insertId": insertId, "amount": amount}
    try:
        resp = requests.get(N8N_WEBHOOK_URL, params=params, timeout=10)
        resp.raise_for_status()
        ct = resp.headers.get("content-type", "")
        return {
            "sent": True,
            "forwarded_params": params,
            "n8n_response": resp.json() if ct.startswith("application/json") else resp.text,
        }
    except requests.RequestException as e:
        logging.error("Error calling n8n webhook: %s", e)
        raise HTTPException(status_code=502, detail=f"n8n unreachable: {e}")

# ------------ Diagnostics ------------
@app.get("/_diag/token")
def diag_token():
    src = "metadata" if _metadata_token_available() else "gcloud/local"
    try:
        token = get_access_token()
        return {"ok": True, "source": src, "token_prefix": token[:12] + "..."}
    except HTTPException as e:
        raise e

@app.get("/_diag/bq")
def diag_bq():
    sql = "SELECT 1 AS ok"
    return run_bq_query(sql)

@app.get("/bq/exists")
def bq_exists():
    sql = f"""
    SELECT table_name
    FROM `{PROJECT_ID}.{DATASET}.INFORMATION_SCHEMA.TABLES`
    WHERE table_name = '{TABLE}'
    """
    return run_bq_query(sql)

# ------------ Metrics: CAC & ROAS ------------
@app.get("/metrics")
def compare_periods(
    first_start: str = Query(..., description="Start date of first period (YYYY-MM-DD)"),
    first_end: str = Query(..., description="End date of first period (YYYY-MM-DD)"),
    second_start: str = Query(..., description="Start date of second period (YYYY-MM-DD)"),
    second_end: str = Query(..., description="End date of second period (YYYY-MM-DD)")
):
    """
    Compare two custom periods with CAC and ROAS metrics including deltas
    Example: /metrics/compare-periods?first_start=2025-05-01&first_end=2025-05-31&second_start=2025-06-01&second_end=2025-06-30
    """
    # Validate date formats
    try:
        first_start_dt = datetime.strptime(first_start, "%Y-%m-%d").date()
        first_end_dt = datetime.strptime(first_end, "%Y-%m-%d").date()
        second_start_dt = datetime.strptime(second_start, "%Y-%m-%d").date()
        second_end_dt = datetime.strptime(second_end, "%Y-%m-%d").date()
    except ValueError:
        raise HTTPException(status_code=400, detail="Invalid date format. Use YYYY-MM-DD")
    
    # Validate date ranges
    if first_start_dt > first_end_dt:
        raise HTTPException(status_code=400, detail="First period start must be before end")
    if second_start_dt > second_end_dt:
        raise HTTPException(status_code=400, detail="Second period start must be before end")

    # Build dynamic query
    sql = f"""
WITH base AS (
  SELECT
    DATE(date) AS dt,
    SUM(spend) AS spend,
    SUM(conversions) AS conv,
    CASE 
      WHEN DATE(date) BETWEEN '{first_start_dt}' AND '{first_end_dt}' THEN 'first_period'
      WHEN DATE(date) BETWEEN '{second_start_dt}' AND '{second_end_dt}' THEN 'second_period'
      ELSE 'other'
    END AS period
  FROM `{PROJECT_ID}.{DATASET}.{TABLE}`
  WHERE DATE(date) BETWEEN '{first_start_dt}' AND '{second_end_dt}'
  GROUP BY dt, period
),
agg AS (
  SELECT
    period,
    SUM(spend) AS spend,
    SUM(conv) AS conv
  FROM base
  WHERE period IN ('first_period', 'second_period')
  GROUP BY period
),
periods AS (
  SELECT 'first_period' AS period UNION ALL SELECT 'second_period'
),
filled AS (
  SELECT
    p.period,
    IFNULL(a.spend, 0) AS spend,
    IFNULL(a.conv, 0) AS conv,
    IFNULL(a.conv, 0) * 100 AS revenue,
    SAFE_DIVIDE(IFNULL(a.spend, 0), NULLIF(IFNULL(a.conv, 0), 0)) AS CAC,
    SAFE_DIVIDE(IFNULL(a.conv, 0) * 100, NULLIF(IFNULL(a.spend, 0), 0)) AS ROAS
  FROM periods p
  LEFT JOIN agg a USING (period)
),
pivoted AS (
  SELECT
    MAX(IF(period='second_period', spend, NULL)) AS spend_second,
    MAX(IF(period='first_period', spend, NULL)) AS spend_first,
    MAX(IF(period='second_period', conv, NULL)) AS conv_second,
    MAX(IF(period='first_period', conv, NULL)) AS conv_first,
    MAX(IF(period='second_period', revenue, NULL)) AS revenue_second,
    MAX(IF(period='first_period', revenue, NULL)) AS revenue_first,
    MAX(IF(period='second_period', CAC, NULL)) AS CAC_second,
    MAX(IF(period='first_period', CAC, NULL)) AS CAC_first,
    MAX(IF(period='second_period', ROAS, NULL)) AS ROAS_second,
    MAX(IF(period='first_period', ROAS, NULL)) AS ROAS_first
  FROM filled
)
SELECT
  spend_second,
  spend_first,
  conv_second,
  conv_first,
  revenue_second,
  revenue_first,
  ROUND(CAC_second, 2) AS CAC_second,
  ROUND(CAC_first, 2) AS CAC_first,
  ROUND(ROAS_second, 2) AS ROAS_second,
  ROUND(ROAS_first, 2) AS ROAS_first,
  ROUND(SAFE_DIVIDE(spend_second - spend_first, NULLIF(spend_first, 0)) * 100, 2) AS spend_delta_pct,
  ROUND(SAFE_DIVIDE(conv_second - conv_first, NULLIF(conv_first, 0)) * 100, 2) AS conversions_delta_pct,
  ROUND(SAFE_DIVIDE(revenue_second - revenue_first, NULLIF(revenue_first, 0)) * 100, 2) AS revenue_delta_pct,
  ROUND(SAFE_DIVIDE(CAC_second - CAC_first, NULLIF(CAC_first, 0)) * 100, 2) AS CAC_delta_pct,
  ROUND(SAFE_DIVIDE(ROAS_second - ROAS_first, NULLIF(ROAS_first, 0)) * 100, 2) AS ROAS_delta_pct
FROM pivoted
    """

    # Execute query
    result = run_bq_query(sql)
    
    # Parse results
    rows = result.get("rows", [])
    if not rows:
        return {
            "periods": {
                "first": {"start": first_start, "end": first_end},
                "second": {"start": second_start, "end": second_end}
            },
            "metrics": {
                "spend_first": 0,
                "spend_second": 0,
                "conversions_first": 0,
                "conversions_second": 0,
                "revenue_first": 0,
                "revenue_second": 0,
                "CAC_first": None,
                "CAC_second": None,
                "ROAS_first": None,
                "ROAS_second": None
            },
            "deltas_pct": {
                "spend": None,
                "conversions": None,
                "revenue": None,
                "CAC": None,
                "ROAS": None
            }
        }

    # Extract values
    row = rows[0]
    fields = [f["name"] for f in result["schema"]["fields"]]
    values = {field: row["f"][i]["v"] for i, field in enumerate(fields)}
    
    # Convert to appropriate data types
    def safe_float(value):
        return float(value) if value not in (None, "null") else None
    
    spend_second = safe_float(values.get("spend_second"))
    spend_first = safe_float(values.get("spend_first"))
    conv_second = safe_float(values.get("conv_second"))
    conv_first = safe_float(values.get("conv_first"))
    revenue_second = safe_float(values.get("revenue_second"))
    revenue_first = safe_float(values.get("revenue_first"))
    cac_second = safe_float(values.get("CAC_second"))
    cac_first = safe_float(values.get("CAC_first"))
    roas_second = safe_float(values.get("ROAS_second"))
    roas_first = safe_float(values.get("ROAS_first"))

    return {
        "periods": {
            "first": {"start": first_start, "end": first_end},
            "second": {"start": second_start, "end": second_end}
        },
        "metrics": {
            "spend_first": spend_first or 0,
            "spend_second": spend_second or 0,
            "conversions_first": int(conv_first or 0),
            "conversions_second": int(conv_second or 0),
            "revenue_first": revenue_first or 0,
            "revenue_second": revenue_second or 0,
            "CAC_first": cac_first,
            "CAC_second": cac_second,
            "ROAS_first": roas_first,
            "ROAS_second": roas_second
        },
        "deltas_pct": {
            "spend": safe_float(values.get("spend_delta_pct")),
            "conversions": safe_float(values.get("conversions_delta_pct")),
            "revenue": safe_float(values.get("revenue_delta_pct")),
            "CAC": safe_float(values.get("CAC_delta_pct")),
            "ROAS": safe_float(values.get("ROAS_delta_pct"))
        }
    }

@app.get("/metadata/months-available")
def get_available_months():
    """
    Get available months in the dataset with record counts
    Returns list of months with start/end dates and record counts
    """
    sql = f"""
SELECT
  DATE_TRUNC(DATE(date), MONTH) as data_month,
  MIN(DATE(date)) as month_start,
  MAX(DATE(date)) as month_end,
  COUNT(*) as record_count
FROM `{PROJECT_ID}.{DATASET}.{TABLE}`
GROUP BY data_month
ORDER BY data_month DESC
    """

    # Execute query
    result = run_bq_query(sql)
    
    # Parse results
    rows = result.get("rows", [])
    months_data = []
    
    for row in rows:
        fields = [f["name"] for f in result["schema"]["fields"]]
        values = {field: row["f"][i]["v"] for i, field in enumerate(fields)}
        
        months_data.append({
            "data_month": values["data_month"],
            "month_start": values["month_start"],
            "month_end": values["month_end"],
            "record_count": int(values["record_count"])
        })
    
    return {
        "available_months": months_data,
        "total_months": len(months_data)
    }    


@app.on_event("startup")
async def show_routes():
    paths = [getattr(r, "path", str(r)) for r in app.router.routes]
    logging.info("Registered routes: %s", paths)
