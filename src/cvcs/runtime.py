"""Provider-neutral execution boundary for resolved cognitive manifests."""

from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from typing import Any

from cvcs.canonical import canonical_json
from cvcs.errors import CVCSError


@dataclass(frozen=True)
class RunResult:
    output: Any
    latency_ms: int


class RuntimeError(CVCSError):
    pass


class CommandRuntime:
    """Run an interpreter as a subprocess using a stable JSON stdin/stdout contract.

    The command receives ``decision_type``, ``input``, and a fully resolved CVCS
    manifest on stdin. It must emit exactly one JSON value on stdout. Provider SDKs,
    agent frameworks, and local models can all be hidden behind this boundary.
    """

    def __init__(self, command: list[str]):
        if not command:
            raise ValueError("runtime command cannot be empty")
        self.command = command

    def run(self, *, decision_type: str, input_value: Any, manifest: dict[str, Any]) -> RunResult:
        request = {
            "decision_type": decision_type,
            "input": input_value,
            "manifest": manifest,
        }
        started = time.perf_counter()
        completed = subprocess.run(
            self.command,
            input=canonical_json(request),
            text=True,
            capture_output=True,
            check=False,
        )
        latency_ms = round((time.perf_counter() - started) * 1000)
        if completed.returncode != 0:
            detail = completed.stderr.strip() or f"exit status {completed.returncode}"
            raise RuntimeError(f"runtime failed: {detail}")
        try:
            output = json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError("runtime did not return valid JSON") from exc
        return RunResult(output=output, latency_ms=latency_ms)


def structural_diff(before: Any, after: Any, path: str = "") -> list[dict[str, Any]]:
    """Return a small JSON-Pointer-like explanation of observable output drift."""
    if type(before) is not type(after):
        return [{"path": path or "/", "change": "modified", "before": before, "after": after}]
    if isinstance(before, dict):
        result: list[dict[str, Any]] = []
        for key in sorted(before.keys() | after.keys()):
            child = f"{path}/{str(key).replace('~', '~0').replace('/', '~1')}"
            if key not in before:
                result.append({"path": child, "change": "added", "after": after[key]})
            elif key not in after:
                result.append({"path": child, "change": "removed", "before": before[key]})
            else:
                result.extend(structural_diff(before[key], after[key], child))
        return result
    if isinstance(before, list):
        if before == after:
            return []
        return [{"path": path or "/", "change": "modified", "before": before, "after": after}]
    if before != after:
        return [{"path": path or "/", "change": "modified", "before": before, "after": after}]
    return []

