from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


def test_healthz():
    assert client.get("/healthz").status_code == 200


def test_metro_quote():
    res = client.post(
        "/api/shipping/quote",
        json={
            "address": {"line1": "1 MG Rd", "city": "Bengaluru", "pincode": "560001"},
            "items": [{"productId": "p-1", "quantity": 1, "priceSnapshot": 100}],
        },
    )
    assert res.status_code == 200
    assert res.json()["zone"] == "metro"


def test_free_shipping_over_threshold():
    res = client.post(
        "/api/shipping/quote",
        json={
            "address": {"line1": "1 MG Rd", "city": "Bengaluru", "pincode": "560001"},
            "items": [{"productId": "p-1", "quantity": 1, "priceSnapshot": 9000}],
        },
    )
    assert res.json()["freeShippingApplied"] is True
    assert res.json()["cost"] == 0.0


def test_bulk_surcharge():
    res = client.post(
        "/api/shipping/quote",
        json={
            "address": {"line1": "x", "city": "y", "pincode": "999999"},
            "items": [{"productId": "p-1", "quantity": 10, "priceSnapshot": 10}],
        },
    )
    assert res.json()["cost"] > 149.0


def test_zones_endpoint():
    assert client.get("/api/shipping/zones").status_code == 200
