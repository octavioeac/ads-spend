# api/Dockerfile
FROM python:3.11-slim

WORKDIR /app
ENV PYTHONUNBUFFERED=1

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Arranca uvicorn atado a 0.0.0.0 y al puerto que Cloud Run inyecta
CMD ["bash", "-lc", "uvicorn api.main:app --host 0.0.0.0 --port ${PORT:-8080}"]
