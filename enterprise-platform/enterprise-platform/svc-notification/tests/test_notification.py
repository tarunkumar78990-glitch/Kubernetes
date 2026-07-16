from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


def test_healthz():
    assert client.get("/healthz").status_code == 200


def test_send_order_confirmation():
    res = client.post(
        "/api/notifications/send",
        json={
            "userId": "usr-1",
            "channel": "email",
            "template": "order_confirmation",
            "data": {"orderId": "ord-1", "total": 999},
        },
    )
    assert res.status_code == 202
    assert "ord-1" in res.json()["body"]


def test_unknown_template_rejected():
    res = client.post(
        "/api/notifications/send",
        json={"userId": "u", "channel": "email", "template": "nope", "data": {}},
    )
    assert res.status_code == 400


def test_missing_template_field_rejected():
    res = client.post(
        "/api/notifications/send",
        json={
            "userId": "u",
            "channel": "email",
            "template": "order_confirmation",
            "data": {},
        },
    )
    assert res.status_code == 400


def test_bad_channel_rejected():
    res = client.post(
        "/api/notifications/send",
        json={"userId": "u", "channel": "pigeon", "template": "welcome", "data": {"name": "x"}},
    )
    assert res.status_code == 400
