"""Command-line interface for the CVCS local ledger."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from cvcs.canonical import short_hash
from cvcs.errors import CVCSError
from cvcs.repository import Repository
from cvcs.runtime import CommandRuntime


def _json_value(value: str) -> Any:
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value


def _actor(args: argparse.Namespace) -> str:
    return args.actor or Repository.default_actor()


def _repo() -> Repository:
    return Repository.discover()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cvcs",
        description="Version control for AI cognition and context.",
    )
    parser.add_argument("--actor", help="actor written to the audit log (or CVCS_ACTOR)")
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init", help="initialize a cognitive repository")
    init.add_argument("path", nargs="?", default=".")
    init.add_argument("--name")

    export = sub.add_parser("export", help="export a portable canonical JSONL bundle")
    export.add_argument("path", nargs="?", default="-", help="destination or - for stdout")

    import_command = sub.add_parser("import", help="create a repository from a JSONL bundle")
    import_command.add_argument("bundle", help="bundle path or - for stdin")
    import_command.add_argument("path", nargs="?", default=".", help="new repository path")

    commit = sub.add_parser("commit", help="commit one context path")
    commit.add_argument("path", help="logical path, e.g. prompts/system")
    commit.add_argument("value", help="JSON value or plain text")
    commit.add_argument("-t", "--type", default="context")
    commit.add_argument("-m", "--message", required=True)

    remove = sub.add_parser("remove", help="remove a path in a new commit")
    remove.add_argument("path")
    remove.add_argument("-m", "--message", required=True)

    branch = sub.add_parser("branch", help="create a branch at HEAD")
    branch.add_argument("name")

    checkout = sub.add_parser("checkout", help="switch the active branch")
    checkout.add_argument("name")

    sub.add_parser("status", help="show repository and HEAD")

    log = sub.add_parser("log", help="show the cognitive event log")
    log.add_argument("-n", "--limit", type=int, default=20)
    log.add_argument("--json", action="store_true")

    show = sub.add_parser("show", help="show a content-addressed object")
    show.add_argument("hash")

    diff = sub.add_parser("diff", help="diff two cognitive commits")
    diff.add_argument("base")
    diff.add_argument("compare")

    resolve = sub.add_parser("resolve", help="resolve a commit into a runtime manifest")
    resolve.add_argument("revision", nargs="?", default="HEAD")

    execute = sub.add_parser("run", help="run and record a decision through an interpreter")
    execute.add_argument("decision_type")
    execute.add_argument("--input", required=True)
    execute.add_argument("--model", required=True)
    execute.add_argument("--commit", default="HEAD")
    execute.add_argument(
        "--command", dest="runtime_command", required=True, nargs=argparse.REMAINDER
    )

    decision = sub.add_parser("decision", help="record a model decision")
    decision.add_argument("decision_type")
    decision.add_argument("--input", required=True)
    decision.add_argument("--output", required=True)
    decision.add_argument("--model", required=True)

    replay = sub.add_parser("replay", help="causally replay a recorded decision")
    replay.add_argument("decision_id")
    replay.add_argument("--model", required=True)
    replay.add_argument("--commit", default="HEAD")
    replay.add_argument(
        "--command", dest="runtime_command", required=True, nargs=argparse.REMAINDER
    )

    correct = sub.add_parser("correct", help="record a human correction")
    correct.add_argument("decision_id")
    correct.add_argument("--output", required=True)
    correct.add_argument("--reason")
    correct.add_argument(
        "--scope", choices=("output", "partial", "routing", "policy"), default="output"
    )

    propose = sub.add_parser("propose-rule", help="propose context from correction evidence")
    propose.add_argument("correction_ids", nargs="+")
    propose.add_argument("--path", required=True)
    propose.add_argument("--content", required=True)
    propose.add_argument("--summary", required=True)
    propose.add_argument("--type", default="policy")

    ratify = sub.add_parser("ratify-rule", help="approve a proposal into a context commit")
    ratify.add_argument("proposal_id")
    ratify.add_argument("--message", required=True)

    sub.add_parser("queue", help="show corrections waiting to become context")
    sub.add_parser("learning", help="show proposed rules awaiting ratification")
    sub.add_parser("rebuild", help="rebuild query projections from the event log")
    sub.add_parser("verify", help="verify the event chain and content objects")
    return parser


def run(args: argparse.Namespace) -> int:
    actor = _actor(args)
    if args.command == "init":
        repo = Repository.init(Path(args.path), name=args.name, actor=actor)
        print(f"initialized {repo.metadata('name')} at {repo.control_dir}")
        return 0
    if args.command == "import":
        if args.bundle == "-":
            repo = Repository.import_bundle(Path(args.path), sys.stdin)
        else:
            with Path(args.bundle).open(encoding="utf-8") as source:
                repo = Repository.import_bundle(Path(args.path), source)
        print(f"imported {repo.metadata('name')} at {repo.control_dir}")
        return 0

    repo = _repo()
    if args.command == "export":
        if args.path == "-":
            repo.export_bundle(sys.stdout)
        else:
            with Path(args.path).open("w", encoding="utf-8", newline="\n") as destination:
                result = repo.export_bundle(destination)
            print(
                f"exported {result['events']} events and {result['objects']} objects "
                f"to {args.path}"
            )
    elif args.command == "commit":
        commit_hash = repo.commit(
            {args.path: (args.type, _json_value(args.value))},
            message=args.message,
            actor=actor,
        )
        print(f"[{repo.current_branch} {short_hash(commit_hash)}] {args.message}")
    elif args.command == "remove":
        commit_hash = repo.commit({args.path: None}, message=args.message, actor=actor)
        print(f"[{repo.current_branch} {short_hash(commit_hash)}] {args.message}")
    elif args.command == "branch":
        repo.create_branch(args.name, actor=actor)
        print(f"created branch {args.name}")
    elif args.command == "checkout":
        repo.checkout(args.name, actor=actor)
        print(f"switched to {args.name}")
    elif args.command == "status":
        head = repo.head()
        print(f"repository: {repo.metadata('name')}")
        print(f"branch:     {repo.current_branch}")
        print(f"head:       {head or '(unborn)'}")
    elif args.command == "log":
        events = repo.events(limit=args.limit)
        if args.json:
            print(json.dumps(events, indent=2, ensure_ascii=False))
        else:
            for event in events:
                print(
                    f"{event['sequence']:>4} {short_hash(event['hash'])} "
                    f"{event['type']:<24} {event['actor']}"
                )
    elif args.command == "show":
        print(json.dumps(repo.object(args.hash), indent=2, ensure_ascii=False))
    elif args.command == "diff":
        print(json.dumps(repo.diff(args.base, args.compare), indent=2))
    elif args.command == "resolve":
        print(json.dumps(repo.resolve_manifest(args.revision), indent=2, ensure_ascii=False))
    elif args.command == "run":
        command = _runtime_command(args.runtime_command)
        manifest = repo.resolve_manifest(args.commit)
        input_value = _json_value(args.input)
        result = CommandRuntime(command).run(
            decision_type=args.decision_type,
            input_value=input_value,
            manifest=manifest,
        )
        decision_id = repo.record_decision(
            decision_type=args.decision_type,
            input_value=input_value,
            output_value=result.output,
            model=args.model,
            actor=actor,
            metadata={
                "manifest_hash": manifest["manifest_hash"],
                "latency_ms": result.latency_ms,
            },
            commit_hash=manifest["commit_hash"],
            branch=repo.current_branch if args.commit == "HEAD" else args.commit,
        )
        print(
            json.dumps(
                {"decision_id": decision_id, "output": result.output},
                indent=2,
                ensure_ascii=False,
            )
        )
    elif args.command == "decision":
        decision_id = repo.record_decision(
            decision_type=args.decision_type,
            input_value=_json_value(args.input),
            output_value=_json_value(args.output),
            model=args.model,
            actor=actor,
        )
        print(f"recorded decision {decision_id}")
    elif args.command == "replay":
        command = _runtime_command(args.runtime_command)
        original = repo.decision(args.decision_id)
        manifest = repo.resolve_manifest(args.commit)
        result = CommandRuntime(command).run(
            decision_type=original["decision_type"],
            input_value=original["input"],
            manifest=manifest,
        )
        replay = repo.record_replay(
            original["id"],
            replay_commit_hash=manifest["commit_hash"],
            model=args.model,
            output=result.output,
            latency_ms=result.latency_ms,
            actor=actor,
        )
        print(json.dumps(replay, indent=2, ensure_ascii=False))
    elif args.command == "correct":
        correction_id = repo.correct(
            args.decision_id,
            _json_value(args.output),
            actor=actor,
            reason=args.reason,
            scope=args.scope,
        )
        print(f"recorded correction {correction_id}")
    elif args.command == "propose-rule":
        proposal_id = repo.propose_rule(
            args.correction_ids,
            target_path=args.path,
            rule_content=_json_value(args.content),
            summary=args.summary,
            blob_type=args.type,
            actor=actor,
        )
        print(f"proposed rule {proposal_id}")
    elif args.command == "ratify-rule":
        commit_hash = repo.ratify_rule(
            args.proposal_id, message=args.message, actor=actor
        )
        print(f"ratified proposal in commit {commit_hash}")
    elif args.command == "queue":
        print(json.dumps(repo.correction_queue(), indent=2, ensure_ascii=False))
    elif args.command == "learning":
        print(json.dumps(repo.learning_queue(), indent=2, ensure_ascii=False))
    elif args.command == "rebuild":
        result = repo.rebuild_projections()
        print(
            f"rebuilt {result['refs']} refs, {result['decisions']} decisions, "
            f"{result['corrections']} corrections, {result['replays']} replays, "
            f"and {result['proposals']} proposals"
        )
    elif args.command == "verify":
        result = repo.verify()
        print(f"verified {result['events']} events and {result['objects']} objects")
    return 0


def _runtime_command(values: list[str]) -> list[str]:
    command = values[1:] if values and values[0] == "--" else values
    if not command:
        raise ValueError("runtime command is required after --")
    return command


def main(argv: list[str] | None = None) -> int:
    try:
        return run(build_parser().parse_args(argv))
    except (CVCSError, ValueError) as exc:
        print(f"cvcs: {exc}", file=sys.stderr)
        return 2
