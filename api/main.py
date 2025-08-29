# api/main.py
from fastapi import FastAPI, HTTPException, Query
import logging
import requests
import os

app = FastAPI(title="metrics-api")

# n8n webhook URL (test mode). Replace with /webhook/... when workflow is active.
N8N_WEBHOOK_URL = "http://34.171.79.204/webhook-test/d788d010-a7da-4e1d-ad89-addc572535f6"

# --- BigQuery configuration ---
PROJECT_ID = os.getenv("PROJECT_ID", "n8n-ads-spend")
DATASET = os.getenv("BQ_DATASET", "ads_warehouse")
TABLE   = os.getenv("BQ_TABLE",   "ads_spend_raw")
BQ_QUERY_URL = f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT_ID}/queries"
METADATA_TOKEN_URL = "http://metadata/computeMetadata/v1/instance/service-accounts/default/token"

def get_access_token() -> str:
    """
    Retrieve an access token from the GCP metadata server (works on GCE/Cloud Run with attached service account).
    """
    try:
        r = requests.get(METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}, timeout=5)
        r.raise_for_status()
        return r.json()["access_token"]
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Cannot get GCP access token: {e}")

def run_bq_query(sql: str, timeout_sec: int = 30) -> dict:
    """
    Run a synchronous BigQuery query using the REST API.
    """
    token = get_access_token()
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    body = {"query": sql, "useLegacySql": False}
    try:
        resp = requests.post(BQ_QUERY_URL, headers=headers, json=body, timeout=timeout_sec)
        resp.raise_for_status()
        return resp.json()
    except requests.RequestException as e:
        raise HTTPException(status_code=502, detail=f"BigQuery error: {e}")

@app.get("/")
def root():
    return {"ok": True, "service": "metrics-api"}

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/trigger-n8n")
def trigger_n8n(insertId: str = Query(...), amount: float = Query(...)):
    """
    Triggers the n8n webhook by forwarding parameters as querystring.
    Example: /trigger-n8n?insertId=abc123&amount=99.5
    """
    params = {"insertId": insertId, "amount": amount}
    try:
        resp = requests.get(N8N_WEBHOOK_URL, params=params, timeout=10)
        resp.raise_for_status()
        return {
            "sent": True,
            "forwarded_params": params,
            "n8n_response": resp.json() if resp.headers.get("content-type", "").startswith("application/json") else resp.text,
        }
    except requests.RequestException as e:
        logging.error("Error calling n8n webhook: %s", e)
        raise HTTPException(status_code=502, detail=f"n8n unreachable: {e}")

# --- New endpoint for CAC and ROAS ---
@app.get("/metrics/cac-roas")
def metrics_cac_roas():
    """
    Returns CAC and ROAS for the last 30 days vs the previous 30 days.
    Includes absolute values and percentage deltas.
    """
    sql = f"""
    WITH base AS (
      SELECT
        DATE(date) AS dt,
        SUM(spend) AS spend,
        SUM(conversions) AS conv
      FROM `{PROJECT_ID}.{DATASET}.{TABLE}`
      WHERE DATE(date) >= DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)
      GROUP BY dt
    ),
    agg AS (
      SELECT
        CASE 
          WHEN dt >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY) THEN "last_30"
          ELSE "prev_30"
        END AS period,
        SUM(spend) AS spend,
        SUM(conv)  AS conv
      FROM base
      GROUP BY period
    )
    SELECT
      period,
      spend,
      conv,
      ROUND(spend / NULLIF(conv,0),2) AS CAC,
      ROUND((conv*100)/NULLIF(spend,0),2) AS ROAS
    FROM agg
    """
    result = run_bq_query(sql)

    rows = result.get("rows", [])
    metrics = {}
    for row in rows:
        vals = {f["name"]: f["v"] for f in row["f"]}
        metrics[vals["period"]] = {
            "spend": float(vals["spend"]),
            "conversions": int(vals["conv"]),
            "CAC": float(vals["CAC"]),
            "ROAS": float(vals["ROAS"]),
        }

    # Calculate percentage deltas if both periods exist
    if "last_30" in metrics and "prev_30" in metrics:
        def pct_delta(new, old):
            return round(((new - old) / old) * 100, 2) if old else None

        metrics["delta"] = {
            "CAC": pct_delta(metrics["last_30"]["CAC"], metrics["prev_30"]["CAC"]),
            "ROAS": pct_delta(metrics["last_30"]["ROAS"], metrics["prev_30"]["ROAS"]),
            "spend": pct_delta(metrics["last_30"]["spend"], metrics["prev_30"]["spend"]),
            "conversions": pct_delta(metrics["last_30"]["conversions"], metrics["prev_30"]["conversions"]),
        }

    return metrics

@app.on_event("startup")
async def show_routes():
    """
    Logs all registered routes when the app starts.
    """
    paths = [getattr(r, "path", str(r)) for r in app.router.routes]
    logging.info("Registered routes: %s", paths)
