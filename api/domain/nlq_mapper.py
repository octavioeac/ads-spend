from datetime import datetime, date, timedelta
from typing import Dict, List, Optional
import re, unicodedata
from dateutil.relativedelta import relativedelta

class NaturalLanguageToAPI:
    def __init__(self, tz_today: Optional[date]=None):
        self.today = tz_today or datetime.now().date()
        self.metric_mapping = {
            'cac':'CAC','roas':'ROAS','spend':'spend','conversions':'conversions','revenue':'revenue',
            'performance':'all','metrics':'all'
        }
        self.months = {
            'january':1,'february':2,'march':3,'april':4,'may':5,'june':6,'july':7,'august':8,
            'september':9,'october':10,'november':11,'december':12,
            'enero':1,'febrero':2,'marzo':3,'abril':4,'mayo':5,'junio':6,'julio':7,'agosto':8,
            'septiembre':9,'setiembre':9,'octubre':10,'noviembre':11,'diciembre':12
        }

    def _norm(self, s:str)->str:
        s = s.lower()
        return ''.join(c for c in unicodedata.normalize('NFD', s) if unicodedata.category(c) != 'Mn')

    def parse_natural_language(self, question: str) -> Optional[Dict]:
        q = self._norm(question)
        metrics = self._extract_metrics(q)
        time_periods = self._extract_time_periods(q)
        if not time_periods:
            return None
        return {
            "metrics": metrics,
            "time_periods": time_periods,
            "api_params": self._generate_date_params(time_periods),
            "endpoint": "/metrics/compare-periods"
        }

    def _extract_metrics(self, q: str):
        if 'cac' in q and 'roas' in q: return ['CAC','ROAS']
        for k,v in self.metric_mapping.items():
            if k in q: return [v] if v!='all' else ['all']
        return ['all']

    def _extract_time_periods(self, q: str):
        periods = []
        m_last = re.search(r'last (\d+) days?', q)
        m_prior = re.search(r'(prior|previous) (\d+) days?', q)
        if m_last and m_prior and int(m_last.group(1)) == int(m_prior.group(2)):
            d = int(m_last.group(1))
            return [{"type":"last","value":d,"unit":"days"},{"type":"prior","value":d,"unit":"days"}]

        if re.search(r'(this|este)\s+month', q) and re.search(r'last\s+month|mes pasado', q):
            return [{"type":"current","unit":"month"},{"type":"last","unit":"month"}]

        mv = re.search(r'([a-z]+)\s+vs\s+([a-z]+)', q)
        if mv and mv.group(1) in self.months and mv.group(2) in self.months:
            return [{"type":"month","value":mv.group(1)}, {"type":"month","value":mv.group(2)}]

        if 'last week' in q and ('prior week' in q or 'previous week' in q):
            return [{"type":"last","unit":"week"},{"type":"prior","unit":"week"}]
        return periods

    def _month_range(self, year:int, month:int):
        start = date(year, month, 1)
        end = (start + relativedelta(months=1)) - timedelta(days=1)
        return start, end

    def _generate_date_params(self, time_periods):
        today = self.today

        if len(time_periods)==2 and all(p.get('unit')=='days' for p in time_periods):
            days = time_periods[0]['value']
            second_end = today
            second_start = today - timedelta(days=days-1)
            first_end = second_start - timedelta(days=1)
            first_start = first_end - timedelta(days=days-1)
            return {"first_start": first_start.isoformat(),"first_end": first_end.isoformat(),
                    "second_start": second_start.isoformat(),"second_end": second_end.isoformat()}

        if len(time_periods)==2 and time_periods[0].get('unit')=='month' and time_periods[0]['type']=='current':
            cur_start, cur_end = self._month_range(today.year, today.month)
            prev_date = cur_start - relativedelta(days=1)
            last_start, last_end = self._month_range(prev_date.year, prev_date.month)
            return {"first_start": last_start.isoformat(),"first_end": last_end.isoformat(),
                    "second_start": cur_start.isoformat(),"second_end": min(cur_end, today).isoformat()}

        if len(time_periods)==2 and all(p['type']=='month' for p in time_periods):
            y = today.year
            m1 = self.months[time_periods[0]['value']]; m2 = self.months[time_periods[1]['value']]
            s1,e1 = self._month_range(y, m1); s2,e2 = self._month_range(y, m2)
            return {"first_start": s1.isoformat(),"first_end": e1.isoformat(),
                    "second_start": s2.isoformat(),"second_end": e2.isoformat()}

        if len(time_periods)==2 and all(p.get('unit')=='week' for p in time_periods):
            end_last = today - timedelta(days=1)
            start_last = end_last - timedelta(days=6)
            end_prior = start_last - timedelta(days=1)
            start_prior = end_prior - timedelta(days=6)
            return {"first_start": start_prior.isoformat(),"first_end": end_prior.isoformat(),
                    "second_start": start_last.isoformat(),"second_end": end_last.isoformat()}
        return {}

    def generate_api_url(self, question: str):
        parsed = self.parse_natural_language(question)
        if not parsed or not parsed['api_params']: return None
        p = parsed['api_params']
        base = "http://localhost:8000/metrics/compare-periods"
        return f"{base}?first_start={p['first_start']}&first_end={p['first_end']}&second_start={p['second_start']}&second_end={p['second_end']}"
