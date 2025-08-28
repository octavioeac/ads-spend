#!/bin/bash
# Variables
PROJECT_ID=$(gcloud config get-value project)
SA_NAME="n8n-bq"
SA_DISPLAY="n8n BigQuery Service Account"
KEY_FILE="n8n-bq-key.json"
BQ_DATASET="ads_warehouse"
BQ_LOCATION="US"

echo "===> Creating Service Account $SA_NAME ..."
gcloud iam service-accounts create $SA_NAME \
  --display-name="$SA_DISPLAY"

echo "===> Assigning BigQuery and Storage roles ..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/bigquery.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"

echo "===> Generating JSON key ..."
gcloud iam service-accounts keys create $KEY_FILE \
  --iam-account="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "===> Enabling required APIs ..."
gcloud services enable bigquery.googleapis.com
gcloud services enable storage.googleapis.com

echo "===> Creating dataset in BigQuery ..."
bq --location=$BQ_LOCATION mk --dataset $PROJECT_ID:$BQ_DATASET

echo "===> Script completed"
echo "Upload the $KEY_FILE file to n8n as a Google Service Account credential."
