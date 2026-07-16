from fastapi import APIRouter
from pydantic import BaseModel
from typing import List

from .logger import log

router = APIRouter()

# Flat-rate zones. Real systems call a carrier API; the shape is the point.
ZONE_RATES = {
    "metro": {"cost": 49.0, "days": 2},
    "urban": {"cost": 79.0, "days": 4},
    "rural": {"cost": 149.0, "days": 7},
}

METRO_PINCODES_PREFIX = ("11", "40", "56", "60", "70", "50")
FREE_SHIPPING_THRESHOLD = 5000.0


class Address(BaseModel):
    line1: str
    city: str
    pincode: str
    country: str = "IN"


class Item(BaseModel):
    productId: str
    quantity: int
    priceSnapshot: float = 0.0


class QuoteRequest(BaseModel):
    address: Address
    items: List[Item]


def classify_zone(pincode: str) -> str:
    if pincode.startswith(METRO_PINCODES_PREFIX):
        return "metro"
    if len(pincode) == 6 and pincode[0] in "123456":
        return "urban"
    return "rural"


@router.post("/shipping/quote")
async def quote(req: QuoteRequest):
    zone = classify_zone(req.address.pincode)
    rate = ZONE_RATES[zone]

    order_value = sum(i.priceSnapshot * i.quantity for i in req.items)
    total_units = sum(i.quantity for i in req.items)

    cost = rate["cost"]
    # Bulk surcharge beyond 5 units
    if total_units > 5:
        cost += (total_units - 5) * 10

    free = order_value >= FREE_SHIPPING_THRESHOLD
    if free:
        cost = 0.0

    log.info(
        "shipping quoted",
        extra={"zone": zone, "cost": cost, "orderValue": order_value},
    )

    return {
        "zone": zone,
        "cost": cost,
        "currency": "INR",
        "estimatedDays": rate["days"],
        "freeShippingApplied": free,
    }


@router.get("/shipping/zones")
async def zones():
    return {"zones": ZONE_RATES, "freeShippingThreshold": FREE_SHIPPING_THRESHOLD}
