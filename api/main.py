# api/main.py
from fastapi import FastAPI, HTTPException, Query
import logging
import requests
import os
import subprocess
from pathlib import Path

app = FastAPI(title="metrics-api")

# n8n webhook URL (test mode). Replace with /webhook/... when workflow is active.
N8N_WEBHOOK_URL = "http://34.171.79.204/webhook-test/d788d010-a7da-4e1d-ad89-addc572535f6"

# --- BigQuery configuration ---
PROJECT_ID = os.getenv("PROJECT_ID", "n8n-ads-spend")
DATASET = os.getenv("BQ_DATASET", "ads_warehouse")
TABLE   = os.getenv("BQ_TABLE",   "ads_spend_raw")
BQ_QUERY_URL = f"https://bigquery.googleapis.com/bigquery/v2/projects/{PROJECT_ID}/queries"
METADATA_TOKEN_URL = "http://metadata/computeMetadata/v1/instance/service-accounts/default/token"

def _metadata_token_available() -> bool:
    """Quick probe to see if metadata server is reachable (Cloud Run / GCE)."""
    try:
        r = requests.get(
            METADATA_TOKEN_URL,
            headers={"Metadata-Flavor": "Google"},
            timeout=1.5,
        )
        return r.status_code == 200
    except requests.RequestException:
        return False

def get_access_token() -> str:
    """
    Obtain an OAuth2 access token in this order:
      1) Metadata server (Cloud Run / GCE) -> recommended in production.
      2) Local dev: `gcloud auth print-access-token`.
      3) If GOOGLE_APPLICATION_CREDENTIALS is set, raise a hint (use google-auth library if needed).
    """
    # 1) Metadata (Cloud Run / GCE)
    if _metadata_token_available():
        try:
            r = requests.get(METADATA_TOKEN_URL, headers={"Metadata-Flavor": "Google"}, timeout=3)
            r.raise_for_status()
            return r.json()["access_token"]
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Cannot get token from metadata server: {e}")

    # 2) Local with gcloud
    try:
        token = subprocess.check_output(
            ["gcloud", "auth", "print-access-token"],
            text=True,
            timeout=5,
        ).strip()
        if token:
            return token
    except Exception:
        pass

    # 3) SA JSON present (we avoid manual JWT here to keep it minimal)
    cred_path = os.getenv("GOOGLE_APPLICATION_CREDENTIALS", "")
    if cred_path and Path(cred_path).exists():
        raise HTTPException(
            status_code=500,
            detail=("Service Account JSON detected via GOOGLE_APPLICATION_CREDENTIALS, "
                    "but this sample uses REST + metadata/gcloud tokens. "
                    "Run under Cloud Run/VM or authenticate locally with 'gcloud auth login', "
                    "or switch to google-auth library for SA JSON.")
        )

    raise HTTPException(
        status_code=500,
        detail=("Cannot obtain an access token. "
                "Run on Cloud Run/VM (metadata), or authenticate locally with 'gcloud auth login'.")
    )

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
        if resp.status_code >= 400:
            # Surface BQ error body for easier debugging
            raise HTTPException(
                status_code=502,
                detail=f"BigQuery HTTP {resp.status_code}: {resp.text[:800]}"
            )
        return resp.json()
    except requests.RequestException as e:
        raise HTTPException(status_code=502, detail=f"BigQuery request failed: {e}")

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
            "conversions": int(float(vals["conv"])) if vals["conv"] is not None else 0,
            "CAC": float(vals["CAC"]) if vals["CAC"] is not None else None,
            "ROAS": float(vals["ROAS"]) if vals["ROAS"] is not None else None,
        }

    # Calculate percentage deltas if both periods exist
    if "last_30" in metrics and "prev_30" in metrics:
        def pct_delta(new, old):
            return round(((new - old) / old) * 100, 2) if (old not in (None, 0)) and (new is not None) else None

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
