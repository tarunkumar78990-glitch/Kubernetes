import os
from collections import Counter

from fastapi import APIRouter

from .http import call_service
from .logger import log

router = APIRouter()

CATALOG_URL = os.getenv("PRODUCT_CATALOG_URL", "http://product-catalog:8080")

# Toy "collaborative filtering": co-purchase counts.
_co_purchases = Counter()
_user_history = {}


@router.get("/recommendations/{user_id}")
async def recommend(user_id: str):
    """Best-effort. Callers treat failure here as a degraded page, not an
    outage - see frontend/src/routes.js."""
    try:
        catalog = await call_service(
            "product-catalog", CATALOG_URL, "/api/products"
        )
        products = catalog.get("products", [])
    except Exception as err:
        log.warning("catalog unavailable, returning empty recs", extra={"err": str(err)})
        return {"userId": user_id, "recommendations": [], "degraded": True}

    history = _user_history.get(user_id, [])

    if history:
        seen_categories = {h["category"] for h in history}
        scored = [
            p for p in products
            if p["category"] in seen_categories
            and p["id"] not in {h["id"] for h in history}
        ]
    else:
        # Cold start: most stocked items as a proxy for popularity.
        scored = sorted(products, key=lambda p: -p.get("stock", 0))

    return {
        "userId": user_id,
        "recommendations": scored[:4],
        "strategy": "category_affinity" if history else "cold_start_popular",
        "degraded": False,
    }


@router.post("/recommendations/{user_id}/viewed")
async def record_view(user_id: str, product: dict):
    history = _user_history.setdefault(user_id, [])
    if not any(h["id"] == product.get("id") for h in history):
        history.append({"id": product.get("id"), "category": product.get("category")})
    # Keep the tail bounded - unbounded per-user state is a memory leak
    # that only shows up in prod.
    _user_history[user_id] = history[-20:]
    return {"recorded": True, "historySize": len(_user_history[user_id])}
