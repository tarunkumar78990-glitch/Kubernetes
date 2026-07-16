import os
import random
import uuid

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from .logger import log

router = APIRouter()

# In prod this key comes from Secret Manager via Workload Identity -
# no JSON key on disk. See k8s/base/deployment.yaml for the KSA annotation.
PAYMENT_GATEWAY_KEY = os.getenv("PAYMENT_GATEWAY_KEY", "dev-fake-key")

_payments = {}


class AuthorizeRequest(BaseModel):
    userId: str
    amount: float = Field(gt=0)
    currency: str = "INR"
    method: str


class CaptureRequest(BaseModel):
    orderId: str


@router.post("/payments/authorize")
async def authorize(req: AuthorizeRequest):
    payment_id = f"pay-{uuid.uuid4().hex[:10]}"

    # Simulated gateway. Deterministic in tests, ~3% decline otherwise so
    # you can actually see the error budget move.
    declined = os.getenv("FORCE_DECLINE") == "true" or random.random() < 0.03

    if declined:
        log.warning(
            "payment declined",
            extra={"paymentId": payment_id, "userId": req.userId},
        )
        return {
            "paymentId": payment_id,
            "status": "DECLINED",
            "reason": "insufficient_funds",
        }

    _payments[payment_id] = {
        "paymentId": payment_id,
        "userId": req.userId,
        "amount": req.amount,
        "currency": req.currency,
        "method": req.method,
        "status": "AUTHORIZED",
    }

    log.info(
        "payment authorized",
        extra={"paymentId": payment_id, "amount": req.amount},
    )
    return _payments[payment_id]


@router.post("/payments/{payment_id}/capture")
async def capture(payment_id: str, req: CaptureRequest):
    payment = _payments.get(payment_id)
    if not payment:
        raise HTTPException(status_code=404, detail="payment_not_found")
    if payment["status"] != "AUTHORIZED":
        raise HTTPException(status_code=409, detail="payment_not_authorizable")

    payment["status"] = "CAPTURED"
    payment["orderId"] = req.orderId

    log.info(
        "payment captured",
        extra={"paymentId": payment_id, "orderId": req.orderId},
    )
    return payment


@router.post("/payments/{payment_id}/refund")
async def refund(payment_id: str):
    payment = _payments.get(payment_id)
    if not payment:
        raise HTTPException(status_code=404, detail="payment_not_found")
    if payment["status"] != "CAPTURED":
        raise HTTPException(status_code=409, detail="only_captured_can_refund")

    payment["status"] = "REFUNDED"
    return payment


@router.get("/payments/{payment_id}")
async def get_payment(payment_id: str):
    payment = _payments.get(payment_id)
    if not payment:
        raise HTTPException(status_code=404, detail="payment_not_found")
    return payment
