from fastapi.testclient import TestClient

from src.main import app

client = TestClient(app)


def test_healthz():
    assert client.get("/healthz").status_code == 200


def test_register_and_login():
    reg = client.post(
        "/api/auth/register",
        json={"email": "a@example.com", "password": "supersecret1", "name": "A"},
    )
    assert reg.status_code == 201

    login = client.post(
        "/api/auth/login",
        json={"email": "a@example.com", "password": "supersecret1"},
    )
    assert login.status_code == 200
    assert "token" in login.json()


def test_duplicate_registration_conflicts():
    client.post(
        "/api/auth/register",
        json={"email": "dup@example.com", "password": "supersecret1", "name": "D"},
    )
    again = client.post(
        "/api/auth/register",
        json={"email": "dup@example.com", "password": "supersecret1", "name": "D"},
    )
    assert again.status_code == 409


def test_short_password_rejected():
    res = client.post(
        "/api/auth/register",
        json={"email": "s@example.com", "password": "short", "name": "S"},
    )
    assert res.status_code == 400


def test_wrong_password_is_401():
    client.post(
        "/api/auth/register",
        json={"email": "b@example.com", "password": "supersecret1", "name": "B"},
    )
    res = client.post(
        "/api/auth/login", json={"email": "b@example.com", "password": "wrongwrong"}
    )
    assert res.status_code == 401


def test_verify_valid_token():
    client.post(
        "/api/auth/register",
        json={"email": "c@example.com", "password": "supersecret1", "name": "C"},
    )
    token = client.post(
        "/api/auth/login",
        json={"email": "c@example.com", "password": "supersecret1"},
    ).json()["token"]

    res = client.get("/api/auth/verify", headers={"Authorization": f"Bearer {token}"})
    assert res.status_code == 200
    assert res.json()["valid"] is True


def test_verify_rejects_tampered_token():
    res = client.get(
        "/api/auth/verify", headers={"Authorization": "Bearer aaa.bbb.ccc"}
    )
    assert res.status_code == 401
