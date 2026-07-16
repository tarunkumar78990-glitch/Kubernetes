import os

os.environ["SERVICE_NAME"] = "payment"

from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


def test_healthz():
    res = client.get("/healthz")
    assert res.status_code == 200
    assert res.json()["status"] == "alive"


def test_metrics_exposed():
    res = client.get("/metrics")
    assert res.status_code == 200
    assert "http_requests_total" in res.text


def test_authorize_success():
    os.environ.pop("FORCE_DECLINE", None)
    res = client.post(
        "/api/payments/authorize",
        json={"userId": "usr-1", "amount": 500.0, "currency": "INR", "method": "card"},
    )
    assert res.status_code == 200
    assert res.json()["status"] in ("AUTHORIZED", "DECLINED")


def test_authorize_rejects_negative_amount():
    res = client.post(
        "/api/payments/authorize",
        json={"userId": "usr-1", "amount": -5, "currency": "INR", "method": "card"},
    )
    assert res.status_code == 422


def test_forced_decline():
    os.environ["FORCE_DECLINE"] = "true"
    res = client.post(
        "/api/payments/authorize",
        json={"userId": "usr-1", "amount": 500.0, "currency": "INR", "method": "card"},
    )
    assert res.json()["status"] == "DECLINED"
    os.environ.pop("FORCE_DECLINE")


def test_capture_unknown_payment_404s():
    res = client.post("/api/payments/pay-nope/capture", json={"orderId": "ord-1"})
    assert res.status_code == 404
