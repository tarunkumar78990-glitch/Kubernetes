"""Prometheus metrics. Names match the Node services deliberately so one
Grafana dashboard and one set of SLO rules cover the whole platform."""
import time

from prometheus_client import Counter, Histogram
from starlette.middleware.base import BaseHTTPMiddleware

HTTP_REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    ["method", "route", "status_code"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5),
)

HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "route", "status_code"],
)

DEPENDENCY_REQUESTS_TOTAL = Counter(
    "dependency_requests_total",
    "Calls made to downstream services",
    ["dependency", "status"],
)


class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        start = time.perf_counter()
        response = await call_next(request)
        elapsed = time.perf_counter() - start

        # Use the route template, not the raw path, or you get unbounded
        # cardinality (one time series per order id - a classic outage).
        route = request.scope.get("route")
        route_path = route.path if route else request.url.path

        labels = {
            "method": request.method,
            "route": route_path,
            "status_code": str(response.status_code),
        }
        HTTP_REQUEST_DURATION.labels(**labels).observe(elapsed)
        HTTP_REQUESTS_TOTAL.labels(**labels).inc()
        return response
