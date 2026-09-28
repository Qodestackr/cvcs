"""Canonical encoding and content addressing primitives."""

from __future__ import annotations

import hashlib
import json
from typing import Any


def canonical_json(value: Any) -> str:
    """Encode JSON deterministically so hashes are stable across runtimes."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode()).hexdigest()


def short_hash(value: str, length: int = 12) -> str:
    return value[:length]

