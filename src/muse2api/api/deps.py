from __future__ import annotations

import hashlib
import hmac

from fastapi import Request

from ..errors import Unauthorized
from ..services.container import Services


def get_services(request: Request) -> Services:
    return request.app.state.services


def _bearer(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return request.headers.get("x-api-key", "").strip()


def _check(provided: str, expected: str) -> None:
    if not expected or not hmac.compare_digest(provided.encode(), expected.encode()):
        raise Unauthorized("invalid or missing API key")


def _matches(provided: str, expected: str) -> bool:
    return bool(expected) and hmac.compare_digest(provided.encode(), expected.encode())


def _identify(request: Request, key_id: str, key_name: str) -> None:
    # Read by the request-log middleware.
    request.state.key_id = key_id
    request.state.key_name = key_name


def require_api_key(request: Request) -> None:
    """Accept the admin key, the legacy single ``api_key``, or any active stored key."""
    svc = get_services(request)
    s = svc.settings
    provided = _bearer(request)
    if not provided:
        raise Unauthorized("invalid or missing API key")
    # The admin key is a superset of the API key.
    if _matches(provided, s.admin_key):
        _identify(request, "admin", "admin")
        return
    if _matches(provided, s.api_key):
        _identify(request, "legacy", "legacy")
        return
    key = svc.keys.verify(provided)
    if key is None:
        raise Unauthorized("invalid or missing API key")
    svc.keys.touch(key)
    _identify(request, key.id, key.name)


def conversation_key(request: Request, user: str | None) -> str | None:
    """The browser driver continues a muse.ai thread only for a non-empty key. Scoping
    ``user`` by the API key keeps two keys that send the same ``user`` apart."""
    key_id = getattr(request.state, "key_id", "")
    if user:
        return f"{key_id}:{user}"
    if not get_services(request).settings.auto_conversation:
        return None

    # Most agent clients don't expose OpenAI's optional ``user`` field. Let clients
    # that support custom headers provide a better id; otherwise use a hash so raw IP
    # addresses and User-Agent strings never enter the account store.
    supplied = request.headers.get("x-muse-conversation-id", "").strip()
    if supplied:
        identity = supplied
    else:
        forwarded = request.headers.get("cf-connecting-ip", "").strip()
        if not forwarded:
            forwarded = request.headers.get("x-forwarded-for", "").split(",", 1)[0].strip()
        if not forwarded and request.client:
            forwarded = request.client.host
        identity = f"{forwarded}\0{request.headers.get('user-agent', '')}"
    digest = hashlib.sha256(identity.encode()).hexdigest()[:20]
    return f"{key_id}:auto-{digest}"


def require_admin_key(request: Request) -> None:
    _check(_bearer(request), get_services(request).settings.effective_admin_key)


def public_base(request: Request) -> str:
    base = get_services(request).settings.public_base
    return base.rstrip("/") if base else str(request.base_url).rstrip("/")
