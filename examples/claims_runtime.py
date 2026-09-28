"""Tiny deterministic interpreter used to demonstrate CVCS's runtime contract."""

from __future__ import annotations

import json
import sys


def main() -> int:
    request = json.load(sys.stdin)
    entries = {entry["path"]: entry for entry in request["manifest"]["entries"]}
    policy = entries["policies/high-value-review"]["content"]
    amount = request["input"]["amount"]
    threshold = policy["review_above"]
    if amount >= threshold:
        output = {
            "route": "human_review",
            "reason": f"claim amount meets the {threshold} review threshold",
        }
    else:
        output = {
            "route": "automatic",
            "reason": f"claim amount is below the {threshold} review threshold",
        }
    json.dump(output, sys.stdout, sort_keys=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

