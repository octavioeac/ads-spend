# api/main.py
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
@app.get("/metrics/cac-roas")
def metrics_cac_roas():
    """
    Returns CAC and ROAS for last 30 days vs previous 30 days.
    Always returns both periods even if one has no data.
    """
    sql = f"""
    WITH base AS (
      SELECT DATE(date) AS dt, SUM(spend) AS spend, SUM(conversions) AS conv
      FROM `{PROJECT_ID}.{DATASET}.{TABLE}`
      WHERE DATE(date) >= DATE_SUB(CURRENT_DATE(), INTERVAL 60 DAY)
      GROUP BY dt
    ),
    agg AS (
      SELECT
        CASE WHEN dt >= DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY) THEN 'last_30' ELSE 'prev_30' END AS period,
        SUM(spend) AS spend,
        SUM(conv)  AS conv
      FROM base
      GROUP BY period
    ),
    periods AS (
      SELECT 'last_30' AS period UNION ALL SELECT 'prev_30'
    )
    SELECT
      periods.period,
      IFNULL(agg.spend, 0) AS spend,
      IFNULL(agg.conv, 0)  AS conv,
      ROUND(IFNULL(agg.spend, 0) / NULLIF(agg.conv, 0), 2) AS CAC,
      ROUND((IFNULL(agg.conv, 0) * 100) / NULLIF(agg.spend, 0), 2) AS ROAS
    FROM periods
    LEFT JOIN agg USING (period)
    """
    result = run_bq_query(sql)

    rows = result.get("rows", [])
    # Build dict keyed by period
    metrics = {}
    for row in rows:
        vals = {f["name"]: f["v"] for f in row["f"]}
        spend = float(vals["spend"]) if vals["spend"] is not None else 0.0
        conv  = float(vals["conv"]) if vals["conv"] is not None else 0.0
        cac   = float(vals["CAC"])  if vals["CAC"]  not in (None, "null") else None
        roas  = float(vals["ROAS"]) if vals["ROAS"] not in (None, "null") else None

        metrics[vals["period"]] = {
            "spend": spend,
            "conversions": int(conv),
            "CAC": cac,
            "ROAS": roas,
        }

    # Ensure both keys exist even if BQ returned only one row (extra safety)
    for p in ("last_30", "prev_30"):
        metrics.setdefault(p, {"spend": 0.0, "conversions": 0, "CAC": None, "ROAS": None})

    # Deltas (%): handle None/0 safely
    def pct_delta(new, old):
        return round(((new - old) / old) * 100, 2) if (old not in (None, 0)) and (new is not None) else None

    metrics["delta"] = {
        "CAC":         pct_delta(metrics["last_30"]["CAC"],  metrics["prev_30"]["CAC"]),
        "ROAS":        pct_delta(metrics["last_30"]["ROAS"], metrics["prev_30"]["ROAS"]),
        "spend":       pct_delta(metrics["last_30"]["spend"], metrics["prev_30"]["spend"]),
        "conversions": pct_delta(metrics["last_30"]["conversions"], metrics["prev_30"]["conversions"]),
    }

    return metrics

@app.on_event("startup")
async def show_routes():
    paths = [getattr(r, "path", str(r)) for r in app.router.routes]
    logging.info("Registered routes: %s", paths)
