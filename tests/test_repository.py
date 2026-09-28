import sys
from io import StringIO
from pathlib import Path

import pytest

from cvcs.errors import ConflictError, IntegrityError
from cvcs.repository import Repository
from cvcs.runtime import CommandRuntime


def test_commit_branch_decide_correct_and_verify(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path, name="claims-agent", actor="alice")

    first = repo.commit(
        {"prompts/system": ("prompt", "You triage insurance claims.")},
        message="establish role",
        actor="alice",
    )
    repo.create_branch("experiment/strict", actor="alice")
    repo.checkout("experiment/strict", actor="alice")
    second = repo.commit(
        {"policies/high-value": ("policy", {"review_above": 10000})},
        message="require review for high-value claims",
        actor="bob",
    )

    assert repo.snapshot(first) == {"prompts/system": repo.snapshot(first)["prompts/system"]}
    assert [item["change"] for item in repo.diff(first, second)] == ["added"]

    decision = repo.record_decision(
        decision_type="claim_triage",
        input_value={"amount": 15000},
        output_value={"route": "automatic"},
        model="example/model-v1",
        actor="agent",
    )
    correction = repo.correct(
        decision,
        {"route": "human_review"},
        reason="High-value claims require review",
        actor="reviewer",
        scope="policy",
    )

    assert correction
    assert repo.correction_queue()[0]["decision_id"] == decision
    assert repo.verify()["events"] == 7


def test_content_addressing_is_deterministic(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path, actor="alice")
    left = repo.put_object("blob", {"b": 2, "a": 1})
    right = repo.put_object("blob", {"a": 1, "b": 2})
    assert left == right


def test_empty_change_is_rejected(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path, actor="alice")
    repo.commit({"prompts/system": ("prompt", "same")}, message="first", actor="alice")
    with pytest.raises(ConflictError, match="nothing changed"):
        repo.commit({"prompts/system": ("prompt", "same")}, message="again", actor="alice")


def test_sqlite_guards_immutable_events(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path, actor="alice")
    with pytest.raises(Exception, match="events are immutable"), repo.connect() as connection:
        connection.execute("UPDATE events SET actor = 'mallory'")


def test_bundle_round_trip_and_projection_rebuild(tmp_path: Path) -> None:
    original = Repository.init(tmp_path / "original", name="portable-agent", actor="alice")
    commit = original.commit(
        {"prompts/system": ("prompt", "Classify the request.")},
        message="initial cognition",
        actor="alice",
    )
    original.create_branch("experiment", actor="alice")
    original.checkout("experiment", actor="alice")
    decision = original.record_decision(
        decision_type="classify",
        input_value={"request": "hello"},
        output_value={"label": "other"},
        model="example/v1",
        actor="runtime",
    )
    original.correct(
        decision,
        {"label": "greeting"},
        reason="Hello is a greeting",
        actor="reviewer",
    )

    exported = StringIO()
    original.export_bundle(exported)
    restored = Repository.import_bundle(tmp_path / "restored", StringIO(exported.getvalue()))
    reexported = StringIO()
    restored.export_bundle(reexported)

    assert reexported.getvalue() == exported.getvalue()
    assert restored.head("main") == commit
    assert restored.current_branch == "experiment"
    assert restored.correction_queue()[0]["decision_id"] == decision
    assert restored.rebuild_projections() == {
        "refs": 2,
        "decisions": 1,
        "corrections": 1,
        "replays": 0,
        "proposals": 0,
    }
    assert restored.verify() == original.verify()


def test_bundle_rejects_tampered_event(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path / "source", actor="alice")
    exported = StringIO()
    repo.export_bundle(exported)
    tampered = exported.getvalue().replace('"actor":"alice"', '"actor":"mallory"')

    with pytest.raises(IntegrityError, match="event chain broken"):
        Repository.import_bundle(tmp_path / "target", StringIO(tampered))


def test_manifest_runtime_and_causal_replay(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path, actor="alice")
    original_commit = repo.commit(
        {"policies/high-value-review": ("policy", {"review_above": 25_000})},
        message="initial threshold",
        actor="alice",
    )
    runtime_path = Path(__file__).parents[1] / "examples" / "claims_runtime.py"
    runtime = CommandRuntime([sys.executable, str(runtime_path)])
    manifest = repo.resolve_manifest(original_commit)
    original = runtime.run(
        decision_type="claim_routing",
        input_value={"amount": 15_000},
        manifest=manifest,
    )
    decision_id = repo.record_decision(
        decision_type="claim_routing",
        input_value={"amount": 15_000},
        output_value=original.output,
        model="test/runtime-v1",
        actor="agent",
    )
    learned_commit = repo.commit(
        {"policies/high-value-review": ("policy", {"review_above": 10_000})},
        message="learned threshold",
        actor="alice",
    )
    replayed = runtime.run(
        decision_type="claim_routing",
        input_value={"amount": 15_000},
        manifest=repo.resolve_manifest(learned_commit),
    )
    replay = repo.record_replay(
        decision_id,
        replay_commit_hash=learned_commit,
        model="test/runtime-v1",
        output=replayed.output,
        latency_ms=replayed.latency_ms,
        actor="worker",
    )

    assert original.output["route"] == "automatic"
    assert replayed.output["route"] == "human_review"
    assert replay["output_matches"] is False
    assert replay["context_diff"][0]["path"] == "policies/high-value-review"
    assert {item["path"] for item in replay["output_diff"]} == {"/reason", "/route"}
    assert repo.rebuild_projections()["replays"] == 1


def test_decision_can_bind_to_non_head_manifest(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path, actor="alice")
    historical = repo.commit(
        {"prompts/system": ("prompt", "version one")}, message="v1", actor="alice"
    )
    repo.commit({"prompts/system": ("prompt", "version two")}, message="v2", actor="alice")
    decision_id = repo.record_decision(
        decision_type="test",
        input_value="input",
        output_value="output",
        model="test/v1",
        actor="agent",
        commit_hash=historical,
    )

    decision = repo.decision(decision_id)
    assert decision["commit_hash"] == historical
    assert decision["branch"] == f"@{historical[:12]}"


def test_correction_proposal_ratification_closes_learning_loop(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path, actor="platform")
    repo.commit(
        {"policies/review": ("policy", {"threshold": 25_000})},
        message="initial policy",
        actor="owner",
    )
    decision_id = repo.record_decision(
        decision_type="routing",
        input_value={"amount": 15_000},
        output_value={"route": "automatic"},
        model="runtime/v1",
        actor="agent",
    )
    correction_id = repo.correct(
        decision_id,
        {"route": "human_review"},
        reason="Operational threshold is 10000",
        scope="policy",
        actor="reviewer",
    )
    proposal_id = repo.propose_rule(
        [correction_id],
        target_path="policies/review",
        rule_content={"threshold": 10_000},
        summary="Lower the review threshold to the operational rule.",
        actor="learning-worker",
    )

    assert repo.learning_queue()[0]["evidence"] == [correction_id]
    commit_hash = repo.ratify_rule(
        proposal_id, message="ratify operational threshold", actor="policy-owner"
    )
    assert repo.proposal(proposal_id)["status"] == "ratified"
    assert repo.proposal(proposal_id)["ratified_commit_hash"] == commit_hash
    assert repo.learning_queue() == []
    assert repo.rebuild_projections()["proposals"] == 1
    assert repo.proposal(proposal_id)["status"] == "ratified"
    bundle = StringIO()
    repo.export_bundle(bundle)
    restored = Repository.import_bundle(tmp_path / "restored", StringIO(bundle.getvalue()))
    assert restored.proposal(proposal_id)["status"] == "ratified"
    assert restored.proposal(proposal_id)["evidence"] == [correction_id]


def test_old_local_schema_is_migrated_forward(tmp_path: Path) -> None:
    repo = Repository.init(tmp_path, actor="platform")
    with repo.connect() as connection:
        connection.execute("DROP TABLE learning_proposals")
        connection.execute("DROP TABLE replays")
        connection.executescript(
            """
            CREATE TRIGGER decisions_immutable_update BEFORE UPDATE ON decisions
            BEGIN SELECT RAISE(ABORT, 'old projection trigger'); END;
            """
        )
        connection.execute(
            "UPDATE metadata SET value = '1' WHERE key = 'schema_version'"
        )

    migrated = Repository(tmp_path)
    assert migrated.metadata("schema_version") == "3"
    with migrated.connect() as connection:
        tables = {
            row["name"]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'"
            ).fetchall()
        }
        old_trigger = connection.execute(
            "SELECT name FROM sqlite_master WHERE name = 'decisions_immutable_update'"
        ).fetchone()
    assert {"replays", "learning_proposals"} <= tables
    assert old_trigger is None
