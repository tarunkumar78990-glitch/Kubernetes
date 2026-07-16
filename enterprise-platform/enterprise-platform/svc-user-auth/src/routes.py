import base64
import hashlib
import hmac
import json
import os
import time
import uuid

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel

from .logger import log

router = APIRouter()

# From Secret Manager in real environments (Workload Identity, no key file).
JWT_SECRET = os.getenv("JWT_SECRET", "dev-only-insecure-secret")
TOKEN_TTL_SECONDS = int(os.getenv("TOKEN_TTL_SECONDS", "3600"))

_users = {}


class RegisterRequest(BaseModel):
    email: str
    password: str
    name: str


class LoginRequest(BaseModel):
    email: str
    password: str


def _hash_password(password: str, salt: bytes) -> str:
    # PBKDF2 - not the fastest, which is the point.
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 120_000)
    return base64.b64encode(salt + dk).decode()


def _verify_password(password: str, stored: str) -> bool:
    raw = base64.b64decode(stored.encode())
    salt, dk = raw[:16], raw[16:]
    candidate = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 120_000)
    return hmac.compare_digest(dk, candidate)


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _issue_token(user_id: str, email: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    payload = {
        "sub": user_id,
        "email": email,
        "iat": int(time.time()),
        "exp": int(time.time()) + TOKEN_TTL_SECONDS,
    }
    segments = [
        _b64url(json.dumps(header, separators=(",", ":")).encode()),
        _b64url(json.dumps(payload, separators=(",", ":")).encode()),
    ]
    signing_input = ".".join(segments).encode()
    signature = hmac.new(JWT_SECRET.encode(), signing_input, hashlib.sha256).digest()
    segments.append(_b64url(signature))
    return ".".join(segments)


def _verify_token(token: str) -> dict:
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
    except ValueError:
        raise HTTPException(status_code=401, detail="malformed_token")

    signing_input = f"{header_b64}.{payload_b64}".encode()
    expected = hmac.new(JWT_SECRET.encode(), signing_input, hashlib.sha256).digest()

    if not hmac.compare_digest(_b64url(expected), sig_b64):
        raise HTTPException(status_code=401, detail="invalid_signature")

    padded = payload_b64 + "=" * (-len(payload_b64) % 4)
    payload = json.loads(base64.urlsafe_b64decode(padded))

    if payload["exp"] < time.time():
        raise HTTPException(status_code=401, detail="token_expired")

    return payload


@router.post("/auth/register", status_code=201)
async def register(req: RegisterRequest):
    if req.email in _users:
        raise HTTPException(status_code=409, detail="email_already_registered")
    if len(req.password) < 8:
        raise HTTPException(status_code=400, detail="password_too_short")

    user_id = f"usr-{uuid.uuid4().hex[:8]}"
    _users[req.email] = {
        "userId": user_id,
        "email": req.email,
        "name": req.name,
        "passwordHash": _hash_password(req.password, os.urandom(16)),
    }

    log.info("user registered", extra={"userId": user_id})
    return {"userId": user_id, "email": req.email, "name": req.name}


@router.post("/auth/login")
async def login(req: LoginRequest):
    user = _users.get(req.email)
    # Same error for unknown user and bad password - don't leak which.
    if not user or not _verify_password(req.password, user["passwordHash"]):
        log.warning("failed login", extra={"email": req.email})
        raise HTTPException(status_code=401, detail="invalid_credentials")

    token = _issue_token(user["userId"], user["email"])
    return {"token": token, "userId": user["userId"], "expiresIn": TOKEN_TTL_SECONDS}


@router.get("/auth/verify")
async def verify(authorization: str = Header(default="")):
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing_bearer_token")
    payload = _verify_token(authorization.removeprefix("Bearer "))
    return {"valid": True, "userId": payload["sub"], "email": payload["email"]}
