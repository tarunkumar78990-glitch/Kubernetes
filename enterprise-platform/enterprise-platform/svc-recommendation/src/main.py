import asyncio
import os
import signal

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from .health import state
from .logger import log
from .metrics import MetricsMiddleware
from .routes import router

SERVICE_NAME = os.getenv("SERVICE_NAME", "recommendation")


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("starting up", extra={"service": SERVICE_NAME})
    state.ready = True
    yield
    # Graceful shutdown: stop reporting ready, give the endpoints
    # controller time to pull us out, THEN drain.
    log.info("shutting down", extra={"service": SERVICE_NAME})
    state.shutting_down = True
    state.ready = False
    await asyncio.sleep(5)


app = FastAPI(title="recommendation", lifespan=lifespan)
app.add_middleware(MetricsMiddleware)


@app.get("/healthz")
async def healthz():
    # Never check dependencies here.
    return {"status": "alive", "service": SERVICE_NAME}


@app.get("/readyz")
async def readyz():
    if state.shutting_down:
        return JSONResponse({"status": "shutting_down"}, status_code=503)
    if not state.ready:
        return JSONResponse({"status": "not_ready"}, status_code=503)
    return {"status": "ready", "service": SERVICE_NAME}


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


app.include_router(router, prefix="/api")
