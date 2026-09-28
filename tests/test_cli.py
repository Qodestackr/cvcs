import json
import sys
from pathlib import Path

from cvcs.cli import main


def test_cli_vertical_slice(tmp_path: Path, monkeypatch, capsys) -> None:
    assert main(["--actor", "alice", "init", str(tmp_path), "--name", "demo"]) == 0
    monkeypatch.chdir(tmp_path)
    assert (
        main(
            [
                "--actor",
                "alice",
                "commit",
                "prompts/system",
                "Be precise.",
                "--type",
                "prompt",
                "--message",
                "initial prompt",
            ]
        )
        == 0
    )
    assert main(["verify"]) == 0
    output = capsys.readouterr().out
    assert "initialized demo" in output
    assert "initial prompt" in output
    assert "verified 2 events and 2 objects" in output


def test_cli_export_import(tmp_path: Path, monkeypatch, capsys) -> None:
    source = tmp_path / "source"
    target = tmp_path / "target"
    bundle = tmp_path / "agent.cvcs.jsonl"
    assert main(["--actor", "alice", "init", str(source), "--name", "portable"]) == 0
    monkeypatch.chdir(source)
    assert main(["export", str(bundle)]) == 0
    assert main(["import", str(bundle), str(target)]) == 0
    monkeypatch.chdir(target)
    assert main(["rebuild"]) == 0
    output = capsys.readouterr().out
    assert "exported 1 events" in output
    assert "imported portable" in output
    assert "rebuilt 1 refs" in output


def test_cli_run_and_replay(tmp_path: Path, monkeypatch, capsys) -> None:
    runtime = Path(__file__).parents[1] / "examples" / "claims_runtime.py"
    assert main(["--actor", "alice", "init", str(tmp_path), "--name", "claims"]) == 0
    monkeypatch.chdir(tmp_path)
    assert (
        main(
            [
                "--actor",
                "alice",
                "commit",
                "policies/high-value-review",
                '{"review_above":25000}',
                "--type",
                "policy",
                "--message",
                "initial threshold",
            ]
        )
        == 0
    )
    capsys.readouterr()
    assert (
        main(
            [
                "--actor",
                "agent",
                "run",
                "claim_routing",
                "--input",
                '{"amount":15000}',
                "--model",
                "demo/v1",
                "--command",
                sys.executable,
                str(runtime),
            ]
        )
        == 0
    )
    decision = json.loads(capsys.readouterr().out)
    assert decision["output"]["route"] == "automatic"
    assert (
        main(
            [
                "--actor",
                "alice",
                "commit",
                "policies/high-value-review",
                '{"review_above":10000}',
                "--type",
                "policy",
                "--message",
                "learned threshold",
            ]
        )
        == 0
    )
    capsys.readouterr()
    assert (
        main(
            [
                "--actor",
                "worker",
                "replay",
                decision["decision_id"],
                "--model",
                "demo/v1",
                "--command",
                sys.executable,
                str(runtime),
            ]
        )
        == 0
    )
    replay = json.loads(capsys.readouterr().out)
    assert replay["output"]["route"] == "human_review"
    assert replay["output_matches"] is False
