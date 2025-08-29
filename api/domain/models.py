from typing import List, Dict, Optional
from pydantic import BaseModel, Field

class ComparePeriodsQuery(BaseModel):
    first_start: str
    first_end: str
    second_start: str
    second_end: str
    metrics: Optional[List[str]] = Field(default_factory=lambda: ["all"])

class ComparePeriodsResult(BaseModel):
    period: str
    spend: float | None = None
    conversions: float | None = None
    revenue: float | None = None
    CAC: float | None = None
    ROAS: float | None = None

class ComparePeriodsResponse(BaseModel):
    first_period: ComparePeriodsResult
    second_period: ComparePeriodsResult

class NLQRequest(BaseModel):
    question: str
    execute: bool = True
