from typing import List, Dict
from data.bq_repository import BigQueryRepository

class MetricsService:
    def __init__(self, repo: BigQueryRepository | None = None):
        self.repo = repo or BigQueryRepository()

    def compare_periods(self, first_start:str, first_end:str, second_start:str, second_end:str, metrics:List[str]) -> Dict:
        rows = self.repo.compare_periods(first_start, first_end, second_start, second_end)
        # normaliza salida a { first_period: {...}, second_period: {...} }
        result_map = { r["period"]: r for r in rows }
        first  = result_map.get("first",  {})
        second = result_map.get("second", {})

        # si metrics != ['all'], filtra llaves
        def filter_metrics(d: Dict):
            if not d: return {}
            if metrics == ["all"]:
                return d
            keep = set(["period"] + metrics)
            return {k:v for k,v in d.items() if k in keep}

        return {
            "first_period": filter_metrics(first),
            "second_period": filter_metrics(second)
        }
