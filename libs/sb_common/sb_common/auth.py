from __future__ import annotations

from typing import Any

from fastapi import HTTPException, Request

import jwt

from .config import settings


def _looks_like_jwt(token: str) -> bool:
    # Typical JWT: header.payload.signature (two dots)
    return token.count(".") == 2


def _verify_jwt(token: str) -> dict[str, Any]:
    if not settings.jwks_url:
        raise HTTPException(status_code=401, detail="unauthorized")

    try:
        jwk_client = jwt.PyJWKClient(settings.jwks_url)
        signing_key = jwk_client.get_signing_key_from_jwt(token)

        options = {
            "verify_aud": bool(settings.jwt_audience),
            "verify_iss": bool(settings.jwt_issuer),
        }

        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            audience=settings.jwt_audience or None,
            issuer=settings.jwt_issuer or None,
            options=options,
        )
        if not isinstance(payload, dict):
            raise HTTPException(status_code=401, detail="unauthorized")
        return payload
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=401, detail="unauthorized")


def require_api_key(request: Request) -> None:
    """Auth dependency for HTTP APIs.

    Controlled by `SB_AUTH_MODE`:
    - `open`: no auth (dev)
    - `api_key`: require `SB_API_KEY` via `X-API-Key` or `Authorization: Bearer <key>`
    - `jwt`: require `Authorization: Bearer <jwt>` validated with JWKS (RS256)
    - `jwt_or_api_key`: accept either (migration)
    """

    mode = (settings.auth_mode or "open").strip().lower()
    if mode not in {"open", "api_key", "jwt", "jwt_or_api_key"}:
        raise HTTPException(status_code=500, detail="auth misconfigured")

    auth = request.headers.get("authorization") or ""

    # open
    if mode == "open":
        return

    # jwt / jwt_or_api_key
    if mode in {"jwt", "jwt_or_api_key"}:
        if not settings.jwks_url:
            raise HTTPException(status_code=500, detail="auth misconfigured")

        if auth.lower().startswith("bearer "):
            token = auth.split(" ", 1)[1].strip()
            if _looks_like_jwt(token):
                request.state.jwt = _verify_jwt(token)
                return

        if mode == "jwt":
            raise HTTPException(status_code=401, detail="unauthorized")

    # api_key / jwt_or_api_key
    expected = (settings.api_key or "").strip()
    if not expected:
        raise HTTPException(status_code=500, detail="auth misconfigured")

    supplied = request.headers.get("x-api-key")
    if supplied is None and auth.lower().startswith("bearer "):
        supplied = auth.split(" ", 1)[1].strip()

    if supplied != expected:
        raise HTTPException(status_code=401, detail="unauthorized")


def require_scopes(*required: str):
    """Dependency factory for RBAC.

    This will be used once endpoints declare their required scopes.
    When SB_RBAC_ENFORCE=0, it is a no-op (useful for local/dev).
    """

    def _dep(request: Request) -> None:
        if not settings.rbac_enforce:
            return

        jwt_payload = getattr(request.state, "jwt", None)
        if not isinstance(jwt_payload, dict):
            raise HTTPException(status_code=401, detail="unauthorized")

        scopes: set[str] = set()
        raw = jwt_payload.get("scope")
        if isinstance(raw, str):
            scopes.update({s for s in raw.split() if s.strip()})
        raw2 = jwt_payload.get("scopes")
        if isinstance(raw2, list):
            scopes.update({str(s) for s in raw2 if s is not None})
        raw3 = jwt_payload.get("scp")
        if isinstance(raw3, list):
            scopes.update({str(s) for s in raw3 if s is not None})

        for r in required:
            if r not in scopes:
                raise HTTPException(status_code=403, detail="forbidden")

    return _dep
