from fastapi import APIRouter, Query
from domain.models import ComparePeriodsQuery, ComparePeriodsResponse
from services.metrics_service import MetricsService

router = APIRouter(prefix="/metrics", tags=["metrics"])
svc = MetricsService()

@router.get("/compare-periods", response_model=dict)  # o ComparePeriodsResponse si quieres tipado estricto
def compare_periods(
    first_start: str = Query(...),
    first_end: str = Query(...),
    second_start: str = Query(...),
    second_end: str = Query(...),
    metrics: str = Query("all")  # "CAC,ROAS" o "all"
):
    metrics_list = ["all"] if metrics.lower() == "all" else [m.strip() for m in metrics.split(",")]
    data = svc.compare_periods(first_start, first_end, second_start, second_end, metrics_list)
    return data
