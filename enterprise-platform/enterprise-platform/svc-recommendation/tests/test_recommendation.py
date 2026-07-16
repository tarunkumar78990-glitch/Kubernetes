from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


def test_healthz():
    assert client.get("/healthz").status_code == 200


def test_metrics_exposed():
    res = client.get("/metrics")
    assert res.status_code == 200


def test_recommendations_degrade_gracefully_when_catalog_down():
    # No catalog reachable in unit tests -> must degrade, not 500.
    res = client.get("/api/recommendations/usr-1")
    assert res.status_code == 200
    assert res.json()["degraded"] is True
    assert res.json()["recommendations"] == []


def test_record_view():
    res = client.post(
        "/api/recommendations/usr-1/viewed",
        json={"id": "p-1001", "category": "furniture"},
    )
    assert res.status_code == 200
    assert res.json()["recorded"] is True
