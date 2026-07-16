"""Service-to-service HTTP client with timeout, retry and metrics."""
import asyncio
import os
import random

import httpx

from .logger import log
from .metrics import DEPENDENCY_REQUESTS_TOTAL

TIMEOUT_S = float(os.getenv("HTTP_TIMEOUT_MS", "3000")) / 1000
RETRIES = int(os.getenv("HTTP_RETRIES", "2"))


async def call_service(name, base_url, path, method="GET", json=None, request_id=""):
    url = f"{base_url}{path}"
    last_err = None

    async with httpx.AsyncClient(timeout=TIMEOUT_S) as client:
        for attempt in range(RETRIES + 1):
            try:
                response = await client.request(
                    method, url, json=json, headers={"x-request-id": request_id}
                )
                response.raise_for_status()
                DEPENDENCY_REQUESTS_TOTAL.labels(dependency=name, status="success").inc()
                return response.json()
            except httpx.HTTPStatusError as err:
                last_err = err
                status = err.response.status_code
                log.warning(
                    "dependency call failed",
                    extra={"dependency": name, "url": url, "status": status},
                )
                # 4xx won't get better on retry.
                if 400 <= status < 500:
                    DEPENDENCY_REQUESTS_TOTAL.labels(
                        dependency=name, status="client_error"
                    ).inc()
                    raise
            except (httpx.RequestError, asyncio.TimeoutError) as err:
                last_err = err
                log.warning(
                    "dependency network error",
                    extra={"dependency": name, "url": url, "attempt": attempt},
                )

            if attempt < RETRIES:
                backoff = min(0.1 * (2**attempt), 1.0) + random.random() * 0.1
                await asyncio.sleep(backoff)

    DEPENDENCY_REQUESTS_TOTAL.labels(dependency=name, status="failure").inc()
    raise last_err
