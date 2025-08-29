from fastapi import FastAPI

app = FastAPI(title="metrics-api")

@app.get("/healthz")
def healthz():
    return {"status": "ok"}
