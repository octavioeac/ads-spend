# api/main.py
from fastapi import FastAPI
import logging

app = FastAPI(title="metrics-api")

@app.get("/")
def root():
    return {"ok": True, "service": "metrics-api"}

@app.get("/healthz")
def healthz():
    return {"status": "ok"}

@app.get("/health")
def health():
    return {"status": "ok"}

@app.on_event("startup")
async def show_routes():
    paths = [getattr(r, "path", str(r)) for r in app.router.routes]
    logging.info("Registered routes: %s", paths)
