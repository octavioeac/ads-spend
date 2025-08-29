FROM python:3.11-slim

# Prevent Python from writing .pyc files and using buffered stdout/stderr
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Install system dependencies (minimal)
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# Environment variables will be injected by Cloud Run:
#   PROJECT_ID, BQ_DATASET, BQ_TABLE, API_KEY
EXPOSE 8080

# Run the FastAPI app with Uvicorn
CMD ["uvicorn", "main:app", "--host=0.0.0.0", "--port=8080"]
