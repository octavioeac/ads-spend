from fastapi import APIRouter, HTTPException
from domain.models import NLQRequest
from domain.nlq_mapper import NaturalLanguageToAPI
from services.metrics_service import MetricsService

router = APIRouter(prefix="/nlq", tags=["nlq"])
nl = NaturalLanguageToAPI()
svc = MetricsService()

@router.post("/parse")
def parse_and_run(req: NLQRequest):
    parsed = nl.parse_natural_language(req.question)
    if not parsed or not parsed.get("api_params"):
        raise HTTPException(status_code=400, detail="No se pudo interpretar periodos de tiempo en la pregunta.")

    params = parsed["api_params"]
    metrics = parsed["metrics"]

    if not req.execute:
        return {
            "metrics": metrics,
            "time_periods": parsed["time_periods"],
            "api_params": params,
            "endpoint": parsed["endpoint"],
            "suggested_url": nl.generate_api_url(req.question)
        }

    data = svc.compare_periods(
        first_start=params["first_start"],
        first_end=params["first_end"],
        second_start=params["second_start"],
        second_end=params["second_end"],
        metrics=metrics
    )
    return {
        "question": req.question,
        "metrics": metrics,
        "ranges": params,
        "result": data
    }
