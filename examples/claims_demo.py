"""A correction-to-context-to-replay demonstration of the CVCS thesis."""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

from cvcs.repository import Repository
from cvcs.runtime import CommandRuntime


def main() -> int:
    root = Path(tempfile.mkdtemp(prefix="cvcs-claims-demo-"))
    runtime_path = Path(__file__).with_name("claims_runtime.py")
    runtime = CommandRuntime([sys.executable, str(runtime_path)])
    repo = Repository.init(root, name="claims-routing-agent", actor="platform")

    original_commit = repo.commit(
        {
            "prompts/system": ("prompt", "Route claims according to active policy."),
            "policies/high-value-review": ("policy", {"review_above": 25_000}),
        },
        message="initial claims cognition",
        actor="policy-team",
    )
    manifest = repo.resolve_manifest(original_commit)
    original_run = runtime.run(
        decision_type="claim_routing",
        input_value={"claim_id": "CLM-1042", "amount": 15_000},
        manifest=manifest,
    )
    decision_id = repo.record_decision(
        decision_type="claim_routing",
        input_value={"claim_id": "CLM-1042", "amount": 15_000},
        output_value=original_run.output,
        model="demo/claims-runtime-v1",
        actor="claims-agent",
        metadata={"manifest_hash": manifest["manifest_hash"]},
    )
    correction_id = repo.correct(
        decision_id,
        {
            "route": "human_review",
            "reason": "claims at or above 10000 require review",
        },
        reason="The documented 25000 threshold is stale; operations use 10000.",
        scope="policy",
        actor="claims-supervisor",
    )

    proposal_id = repo.propose_rule(
        [correction_id],
        target_path="policies/high-value-review",
        rule_content={"review_above": 10_000},
        summary="Operations requires human review for claims from 10000.",
        actor="learning-worker",
    )

    repo.create_branch("learning/lower-review-threshold", actor="policy-team")
    repo.checkout("learning/lower-review-threshold", actor="policy-team")
    learned_commit = repo.ratify_rule(
        proposal_id,
        message="ratify supervisor correction: review claims from 10000",
        actor="policy-team",
    )
    replay_manifest = repo.resolve_manifest(learned_commit)
    replay_run = runtime.run(
        decision_type="claim_routing",
        input_value=repo.decision(decision_id)["input"],
        manifest=replay_manifest,
    )
    replay = repo.record_replay(
        decision_id,
        replay_commit_hash=learned_commit,
        model="demo/claims-runtime-v1",
        output=replay_run.output,
        latency_ms=replay_run.latency_ms,
        actor="replay-worker",
    )

    report = {
        "repository": str(root),
        "production_decision": {
            "id": decision_id,
            "commit": original_commit,
            "output": original_run.output,
        },
        "human_correction": {"id": correction_id, "action": "route to human_review"},
        "learning_proposal": proposal_id,
        "learned_commit": learned_commit,
        "causal_replay": replay,
        "point": (
            "This is not a benchmark score. It is the same historical input replayed "
            "after one governed cognitive change, with the cause and effect preserved."
        ),
    }
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
