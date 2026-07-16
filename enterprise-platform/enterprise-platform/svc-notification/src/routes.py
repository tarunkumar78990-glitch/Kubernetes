import os
import uuid

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Dict, Any

from .logger import log

router = APIRouter()

# Real senders (SendGrid/SES/SNS) would be wired here; the API key comes
# from Secret Manager via Workload Identity.
SMTP_API_KEY = os.getenv("SMTP_API_KEY", "dev-fake-key")

TEMPLATES = {
    "order_confirmation": "Your order {orderId} is confirmed. Total: INR {total}",
    "payment_failed": "Payment for order {orderId} failed. Please retry.",
    "shipped": "Order {orderId} has shipped. Track: {trackingId}",
    "welcome": "Welcome to the store, {name}!",
}

_sent = []


class SendRequest(BaseModel):
    userId: str
    channel: str  # email | sms
    template: str
    data: Dict[str, Any] = {}


@router.post("/notifications/send", status_code=202)
async def send(req: SendRequest):
    if req.template not in TEMPLATES:
        raise HTTPException(status_code=400, detail="unknown_template")
    if req.channel not in ("email", "sms"):
        raise HTTPException(status_code=400, detail="unsupported_channel")

    try:
        body = TEMPLATES[req.template].format(**req.data)
    except KeyError as missing:
        raise HTTPException(
            status_code=400, detail=f"template_missing_field: {missing}"
        )

    notification_id = f"ntf-{uuid.uuid4().hex[:8]}"
    record = {
        "notificationId": notification_id,
        "userId": req.userId,
        "channel": req.channel,
        "template": req.template,
        "body": body,
        "status": "QUEUED",
    }
    _sent.append(record)

    log.info(
        "notification queued",
        extra={"notificationId": notification_id, "template": req.template},
    )
    # 202: we've accepted it, delivery is async. Callers must not block
    # a checkout on this.
    return record


@router.get("/notifications/{notification_id}")
async def get_notification(notification_id: str):
    for n in _sent:
        if n["notificationId"] == notification_id:
            return n
    raise HTTPException(status_code=404, detail="notification_not_found")


@router.get("/notifications")
async def list_notifications(userId: str = ""):
    result = [n for n in _sent if not userId or n["userId"] == userId]
    return {"notifications": result, "count": len(result)}
