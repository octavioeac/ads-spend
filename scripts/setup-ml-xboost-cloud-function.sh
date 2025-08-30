#!/usr/bin/env bash
set -euo pipefail

# ================== CONFIGURE THESE ==================
PROJECT_ID="n8n-ads-spend"
REGION="us-central1"
FUNCTION_NAME="train_roas_model"
BUCKET_MODELOS="roas-models-${PROJECT_ID}"   # GCS bucket for model + encoders
MEMORY="1GiB"
TIMEOUT="540s"
# =====================================================

echo "== Setting project =="
gcloud config set project "$PROJECT_ID" >/dev/null

echo "== Enabling required APIs =="
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

echo "== Creating bucket if missing =="
if gcloud storage buckets describe "gs://${BUCKET_MODELOS}" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Bucket gs://${BUCKET_MODELOS} already exists ✓"
else
  gcloud storage buckets create "gs://${BUCKET_MODELOS}" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access
  echo "Bucket created: gs://${BUCKET_MODELOS} ✓"
fi

echo "== Granting minimum roles to SA (${SA_EMAIL}) =="
# BigQuery: read data + run jobs
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.dataViewer" >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/bigquery.jobUser" >/dev/null
# GCS: manage objects in the model bucket
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_MODELOS}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null
echo "IAM roles applied ✓"

echo "== Preparing clean workdir =="
WORKDIR="cf_roas_train"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "== Writing main.py =="
cat > main.py << 'PY'
import os
import json
import pickle
import pandas as pd
from google.cloud import bigquery, storage
from sklearn.preprocessing import LabelEncoder
import xgboost as xgb

# Bucket where we'll store model + encoders
BUCKET_MODELOS = os.getenv("BUCKET_MODELOS")

def _encode_categoricals(df, cols):
    encoders = {}
    for c in cols:
        le = LabelEncoder()
        df[c] = le.fit_transform(df[c].astype(str))
        encoders[c] = le.classes_.tolist()
    return df, encoders

def train_model(request):
    # 1) Load training data from BigQuery
    bq = bigquery.Client()
    query = """
    SELECT 
      platform, account, country, device, 
      spend, impressions, conversions,
      (conversions * 100 / NULLIF(spend, 0)) AS roas
    FROM `n8n-ads-spend.ads_warehouse.ads_spend_raw`
    WHERE spend > 0 AND conversions IS NOT NULL
      AND conversions > 0
      AND date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAY)
    """
    df = bq.query(query).to_dataframe()

    if df.empty:
        return (json.dumps({"status": "no_data"}), 200, {"Content-Type":"application/json"})

    # 2) Features / target
    X = df[['platform', 'account', 'country', 'device', 'spend', 'impressions']].copy()
    y = df['roas'].astype(float)

    # 3) Encode categoricals
    cat_cols = ['platform', 'account', 'country', 'device']
    X, encoders = _encode_categoricals(X, cat_cols)

    # 4) Train model
    model = xgb.XGBRegressor(
        objective='reg:squarederror',
        n_estimators=100,
        max_depth=6,
        learning_rate=0.1,
        n_jobs=-1
    )
    model.fit(X, y)

    # 5) Persist to GCS
    storage_client = storage.Client()
    bucket = storage_client.bucket(BUCKET_MODELOS)

    model_blob = bucket.blob('roas_model.pkl')
    model_blob.upload_from_string(pickle.dumps(model))

    encoders_blob = bucket.blob('encoders.json')
    encoders_blob.upload_from_string(json.dumps(encoders))

    # 6) Response
    payload = {
        "status": "success",
        "rows_used": int(len(df)),
        "r2_score_in_sample": float(model.score(X, y)),
        "model_path": f"gs://{BUCKET_MODELOS}/roas_model.pkl",
        "timestamp": pd.Timestamp.now(tz='UTC').isoformat()
    }
    return (json.dumps(payload), 200, {"Content-Type":"application/json"})
PY

echo "== Writing requirements.txt =="
cat > requirements.txt << 'REQ'
google-cloud-bigquery
google-cloud-storage
pandas
xgboost
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

echo "== Deploying Cloud Function (Gen 2, public) =="
gcloud functions deploy "$FUNCTION_NAME" \
  --gen2 \
  --runtime python311 \
  --region "$REGION" \
  --source "." \
  --entry-point train_model \
  --trigger-http \
  --allow-unauthenticated \
  --service-account "$SA_EMAIL" \
  --set-env-vars BUCKET_MODELOS="$BUCKET_MODELOS" \
  --memory "$MEMORY" \
  --timeout "$TIMEOUT"

URL="$(gcloud functions describe "$FUNCTION_NAME" --region "$REGION" --format='value(serviceConfig.uri)')"

echo
echo "================= DEPLOYED ================="
echo "Function URL: $URL"
echo
echo "Test with curl (no auth required):"
echo "curl -X POST \"$URL\""
echo "============================================"
