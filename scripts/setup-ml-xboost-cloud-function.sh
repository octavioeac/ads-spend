#!/usr/bin/env bash
set -euo pipefail

# ================== CONFIG ==================
PROJECT_ID="n8n-ads-spend"
REGION="us-central1"
BUCKET_MODELOS="roas-models-${PROJECT_ID}"

TRAIN_FN="train_roas_model"
PRED_FN="predict_roas"

MEMORY="2GiB"
TIMEOUT="540s"
# ============================================

echo "== Setting project =="
gcloud config set project "$PROJECT_ID" >/dev/null

echo "== Enabling APIs =="
gcloud services enable \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com

echo "== Resolving Service Account =="
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
APPENGINE_SA="${PROJECT_ID}@appspot.gserviceaccount.com"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

sa_exists () { gcloud iam service-accounts describe "$1" --project "$PROJECT_ID" >/dev/null 2>&1; }

if sa_exists "$APPENGINE_SA"; then
  SA_EMAIL="$APPENGINE_SA"; echo "Using App Engine default SA: $SA_EMAIL"
elif sa_exists "$COMPUTE_SA"; then
  SA_EMAIL="$COMPUTE_SA"; echo "Using Compute Engine default SA: $SA_EMAIL"
else
  SA_EMAIL="cf-train@${PROJECT_ID}.iam.gserviceaccount.com"
  if ! sa_exists "$SA_EMAIL"; then
    echo "Creating custom SA: $SA_EMAIL"
    gcloud iam service-accounts create cf-train \
      --project "$PROJECT_ID" \
      --display-name "Cloud Functions Training SA"
  fi
  echo "Using custom SA: $SA_EMAIL"
fi

echo "== Ensuring bucket exists =="
if gcloud storage buckets describe "gs://${BUCKET_MODELOS}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Bucket gs://${BUCKET_MODELOS} already exists ✓"
else
  gcloud storage buckets create "gs://${BUCKET_MODELOS}" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access
  echo "Bucket created: gs://${BUCKET_MODELOS} ✓"
fi

echo "== Granting IAM roles to SA =="
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.dataViewer" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.jobUser" >/dev/null
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_MODELOS}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null
echo "IAM roles applied ✓"

echo "== Preparing workdir =="
WORKDIR="cf_roas_train"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "== Writing main.py (train + predict) =="
cat > main.py << 'PY'
import os, json, pickle, logging
import pandas as pd
from typing import List, Dict, Any
from google.cloud import bigquery, storage
from sklearn.preprocessing import LabelEncoder
import xgboost as xgb

logging.getLogger().setLevel(logging.INFO)
BUCKET_MODELOS = os.getenv("BUCKET_MODELOS")

# ==== utils ====
def _error(msg, status=500, **extra):
    logging.error("%s | extra=%s", msg, extra)
    body = {"status":"error", "message": msg}
    body.update(extra)
    return (json.dumps(body), status, {"Content-Type":"application/json"})

def _encode_categoricals(df, cols):
    encoders = {}
    for c in cols:
        le = LabelEncoder()
        df[c] = le.fit_transform(df[c].astype(str))
        encoders[c] = le.classes_.tolist()
    return df, encoders

# ==== TRAIN ====
def train_model(request):
    try:
        if not BUCKET_MODELOS:
            return _error("Missing BUCKET_MODELOS")

        bq = bigquery.Client()
        query = """
        SELECT platform, account, country, device, 
               spend, impressions, conversions,
               (conversions * 100 / NULLIF(spend, 0)) AS roas
        FROM `n8n-ads-spend.ads_warehouse.ads_spend_raw`
        WHERE spend > 0 AND conversions IS NOT NULL
          AND conversions > 0
          AND date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
        """
        df = bq.query(query).to_dataframe()
        logging.info("BQ rows: %d", len(df))

        if df.empty:
            return (json.dumps({"status":"no_data"}), 200, {"Content-Type":"application/json"})

        X = df[['platform','account','country','device','spend','impressions']].copy()
        y = df['roas'].astype(float)

        cat_cols = ['platform','account','country','device']
        X, encoders = _encode_categoricals(X, cat_cols)

        model = xgb.XGBRegressor(
            objective='reg:squarederror',
            n_estimators=100,
            max_depth=6,
            learning_rate=0.1,
            n_jobs=-1
        )
        model.fit(X, y)
        r2 = float(model.score(X, y))

        storage_client = storage.Client()
        bucket = storage_client.bucket(BUCKET_MODELOS)
        bucket.blob('roas_model.pkl').upload_from_string(pickle.dumps(model))
        bucket.blob('encoders.json').upload_from_string(json.dumps(encoders))

        payload = {
            "status": "success",
            "rows_used": int(len(df)),
            "r2_score_in_sample": r2,
            "model_path": f"gs://{BUCKET_MODELOS}/roas_model.pkl",
            "timestamp": pd.Timestamp.now(tz='UTC').isoformat()
        }
        return (json.dumps(payload), 200, {"Content-Type":"application/json"})
    except Exception as e:
        logging.exception("Train error")
        return _error(str(e))

# ==== PREDICT ====
_MODEL, _ENCODERS = None, None

def _load_artifacts():
    global _MODEL, _ENCODERS
    if _MODEL is not None and _ENCODERS is not None:
        return _MODEL, _ENCODERS
    storage_client = storage.Client()
    bucket = storage_client.bucket(BUCKET_MODELOS)
    _MODEL = pickle.loads(bucket.blob("roas_model.pkl").download_as_bytes())
    _ENCODERS = json.loads(bucket.blob("encoders.json").download_as_bytes())
    return _MODEL, _ENCODERS

def _encode_for_predict(df: pd.DataFrame, encoders: Dict[str, List[str]]) -> pd.DataFrame:
    for col, classes in encoders.items():
        mapping = {v: i for i, v in enumerate(classes)}
        df[col] = df[col].astype(str).map(mapping).fillna(-1).astype(int)
    return df

def _prepare_dataframe(payload: Dict[str, Any]) -> pd.DataFrame:
    if "instances" in payload:
        rows = payload["instances"]
        if not isinstance(rows, list):
            raise ValueError("'instances' must be a list")
    else:
        rows = [payload]
    df = pd.DataFrame(rows)
    required = ["platform","account","country","device","spend","impressions"]
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"Missing required fields: {missing}")
    return df[required].copy()

def predict_roas(request):
    try:
        if not BUCKET_MODELOS:
            return _error("Missing BUCKET_MODELOS")

        model, encoders = _load_artifacts()
        payload = request.get_json(silent=True) or {}
        df = _prepare_dataframe(payload)
        cat_cols = ["platform","account","country","device"]
        df[cat_cols] = _encode_for_predict(df[cat_cols], {c: encoders[c] for c in cat_cols})
        preds = model.predict(df)
        return (json.dumps({"predictions": [float(x) for x in preds]}),
                200, {"Content-Type":"application/json"})
    except Exception as e:
        logging.exception("Predict error")
        return (json.dumps({"status":"error","message":str(e)}), 400, {"Content-Type":"application/json"})
PY

echo "== Writing requirements.txt =="
cat > requirements.txt << 'REQ'
google-cloud-bigquery
google-cloud-storage
pandas
db-dtypes
pyarrow
xgboost==2.0.3
scikit-learn
REQ

echo "== Writing .gcloudignore =="
cat > .gcloudignore << 'IGN'
.git
__pycache__/
*.pyc
*.pyo
*.pyd
ENV/
venv/
IGN

echo "== Deploying TRAIN function =="
gcloud functions deploy "$TRAIN_FN" \
  --gen2 --runtime python311 --region "$REGION" \
  --source "." --entry-point train_model \
  --trigger-http --allow-unauthenticated \
  --service-account "$SA_EMAIL" \
  --set-env-vars BUCKET_MODELOS="$BUCKET_MODELOS" \
  --memory "$MEMORY" --timeout "$TIMEOUT"

TRAIN_URL="$(gcloud functions describe "$TRAIN_FN" --region "$REGION" --format='value(serviceConfig.uri)')"
echo "TRAIN URL: $TRAIN_URL"

echo "== Deploying PREDICT function =="
gcloud functions deploy "$PRED_FN" \
  --gen2 --runtime python311 --region "$REGION" \
  --source "." --entry-point predict_roas \
  --trigger-http --allow-unauthenticated \
  --service-account "$SA_EMAIL" \
  --set-env-vars BUCKET_MODELOS="$BUCKET_MODELOS" \
  --memory "$MEMORY" --timeout "$TIMEOUT"

PRED_URL="$(gcloud functions describe "$PRED_FN" --region "$REGION" --format='value(serviceConfig.uri)')"
echo "PREDICT URL: $PRED_URL"

echo
echo "================= DEPLOYED ================="
echo "Train with curl:"
echo "curl -X POST \"$TRAIN_URL\""
echo
echo "Predict single item:"
echo "curl -s -X POST \"$PRED_URL\" -H 'Content-Type: application/json' -d '{\"platform\":\"Google\",\"account\":\"acc1\",\"country\":\"MX\",\"device\":\"mobile\",\"spend\":120,\"impressions\":4000}'"
echo "============================================"
