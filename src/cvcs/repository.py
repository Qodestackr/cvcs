"""The local CVCS repository and append-only cognitive event ledger."""

from __future__ import annotations

import json
import os
import sqlite3
import uuid
from collections.abc import Iterator, Mapping
from contextlib import contextmanager
from datetime import UTC, datetime
from io import TextIOBase
from pathlib import Path
from typing import Any

from cvcs.canonical import canonical_json, digest
from cvcs.errors import ConflictError, IntegrityError, NotARepositoryError

SCHEMA_VERSION = 3
BUNDLE_FORMAT_VERSION = 1


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="microseconds")


SCHEMA = """
PRAGMA foreign_keys = ON;

CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE objects (
    hash TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    type TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    actor TEXT NOT NULL,
    payload TEXT NOT NULL,
    previous_hash TEXT,
    hash TEXT NOT NULL UNIQUE
);

CREATE TABLE refs (
    name TEXT PRIMARY KEY,
    commit_hash TEXT,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (commit_hash) REFERENCES objects(hash)
);

CREATE TABLE decisions (
    id TEXT PRIMARY KEY,
    commit_hash TEXT NOT NULL,
    branch TEXT NOT NULL,
    decision_type TEXT NOT NULL,
    input TEXT NOT NULL,
    output TEXT NOT NULL,
    model TEXT NOT NULL,
    metadata TEXT NOT NULL,
    event_hash TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    FOREIGN KEY (commit_hash) REFERENCES objects(hash),
    FOREIGN KEY (event_hash) REFERENCES events(hash)
);

CREATE TABLE corrections (
    id TEXT PRIMARY KEY,
    decision_id TEXT NOT NULL,
    corrected_output TEXT NOT NULL,
    reason TEXT,
    scope TEXT NOT NULL,
    actor TEXT NOT NULL,
    event_hash TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    FOREIGN KEY (decision_id) REFERENCES decisions(id),
    FOREIGN KEY (event_hash) REFERENCES events(hash)
);

CREATE TABLE replays (
    id TEXT PRIMARY KEY,
    original_decision_id TEXT NOT NULL,
    original_commit_hash TEXT NOT NULL,
    replay_commit_hash TEXT NOT NULL,
    model TEXT NOT NULL,
    output TEXT NOT NULL,
    output_matches INTEGER NOT NULL,
    context_diff TEXT NOT NULL,
    output_diff TEXT NOT NULL,
    latency_ms INTEGER,
    event_hash TEXT NOT NULL,
    recorded_at TEXT NOT NULL,
    FOREIGN KEY (original_decision_id) REFERENCES decisions(id),
    FOREIGN KEY (original_commit_hash) REFERENCES objects(hash),
    FOREIGN KEY (replay_commit_hash) REFERENCES objects(hash),
    FOREIGN KEY (event_hash) REFERENCES events(hash)
);

CREATE TABLE learning_proposals (
    id TEXT PRIMARY KEY,
    target_path TEXT NOT NULL,
    blob_type TEXT NOT NULL,
    rule_content TEXT NOT NULL,
    evidence TEXT NOT NULL,
    summary TEXT NOT NULL,
    status TEXT NOT NULL,
    proposed_by TEXT NOT NULL,
    proposed_event_hash TEXT NOT NULL,
    proposed_at TEXT NOT NULL,
    ratified_commit_hash TEXT,
    ratified_event_hash TEXT,
    ratified_at TEXT,
    FOREIGN KEY (proposed_event_hash) REFERENCES events(hash),
    FOREIGN KEY (ratified_commit_hash) REFERENCES objects(hash),
    FOREIGN KEY (ratified_event_hash) REFERENCES events(hash),
    CHECK (status IN ('proposed', 'ratified'))
);

CREATE TRIGGER objects_immutable_update
BEFORE UPDATE ON objects BEGIN SELECT RAISE(ABORT, 'objects are immutable'); END;
CREATE TRIGGER objects_immutable_delete
BEFORE DELETE ON objects BEGIN SELECT RAISE(ABORT, 'objects are immutable'); END;
CREATE TRIGGER events_immutable_update
BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'events are immutable'); END;
CREATE TRIGGER events_immutable_delete
BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'events are immutable'); END;
"""

MIGRATIONS = {
    2: """
        DROP TRIGGER IF EXISTS decisions_immutable_update;
        DROP TRIGGER IF EXISTS decisions_immutable_delete;
        DROP TRIGGER IF EXISTS corrections_immutable_update;
        DROP TRIGGER IF EXISTS corrections_immutable_delete;
        CREATE TABLE IF NOT EXISTS replays (
            id TEXT PRIMARY KEY,
            original_decision_id TEXT NOT NULL,
            original_commit_hash TEXT NOT NULL,
            replay_commit_hash TEXT NOT NULL,
            model TEXT NOT NULL,
            output TEXT NOT NULL,
            output_matches INTEGER NOT NULL,
            context_diff TEXT NOT NULL,
            output_diff TEXT NOT NULL,
            latency_ms INTEGER,
            event_hash TEXT NOT NULL,
            recorded_at TEXT NOT NULL,
            FOREIGN KEY (original_decision_id) REFERENCES decisions(id),
            FOREIGN KEY (original_commit_hash) REFERENCES objects(hash),
            FOREIGN KEY (replay_commit_hash) REFERENCES objects(hash),
            FOREIGN KEY (event_hash) REFERENCES events(hash)
        );
    """,
    3: """
        CREATE TABLE IF NOT EXISTS learning_proposals (
            id TEXT PRIMARY KEY,
            target_path TEXT NOT NULL,
            blob_type TEXT NOT NULL,
            rule_content TEXT NOT NULL,
            evidence TEXT NOT NULL,
            summary TEXT NOT NULL,
            status TEXT NOT NULL,
            proposed_by TEXT NOT NULL,
            proposed_event_hash TEXT NOT NULL,
            proposed_at TEXT NOT NULL,
            ratified_commit_hash TEXT,
            ratified_event_hash TEXT,
            ratified_at TEXT,
            FOREIGN KEY (proposed_event_hash) REFERENCES events(hash),
            FOREIGN KEY (ratified_commit_hash) REFERENCES objects(hash),
            FOREIGN KEY (ratified_event_hash) REFERENCES events(hash),
            CHECK (status IN ('proposed', 'ratified'))
        );
    """,
}


class Repository:
    """A local-first CVCS repository.

    The event chain is the source of truth. SQLite tables besides ``events`` are
    query-friendly projections and content-addressed objects. They can be rebuilt
    from the log in a future format version.
    """

    def __init__(self, root: Path | str):
        self.root = Path(root).resolve()
        self.control_dir = self.root / ".cvcs"
        self.database_path = self.control_dir / "ledger.db"
        if not self.database_path.is_file():
            raise NotARepositoryError(f"not a CVCS repository: {self.root}")
        self._migrate()

    def _migrate(self) -> None:
        connection = sqlite3.connect(self.database_path)
        try:
            row = connection.execute(
                "SELECT value FROM metadata WHERE key = 'schema_version'"
            ).fetchone()
            if row is None:
                raise IntegrityError("repository has no schema version")
            current = int(row[0])
            if current > SCHEMA_VERSION:
                raise IntegrityError(
                    f"repository schema {current} is newer than supported {SCHEMA_VERSION}"
                )
            for version in range(current + 1, SCHEMA_VERSION + 1):
                migration = MIGRATIONS.get(version)
                if migration is None:
                    raise IntegrityError(f"missing migration for schema version {version}")
                connection.executescript(migration)
                connection.execute(
                    "UPDATE metadata SET value = ? WHERE key = 'schema_version'",
                    (str(version),),
                )
                connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    @classmethod
    def init(
        cls,
        root: Path | str,
        *,
        name: str | None = None,
        actor: str = "system",
    ) -> Repository:
        root_path = Path(root).resolve()
        control_dir = root_path / ".cvcs"
        database_path = control_dir / "ledger.db"
        if database_path.exists():
            raise ConflictError(f"CVCS repository already exists: {root_path}")
        control_dir.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(database_path)
        try:
            connection.executescript(SCHEMA)
            repository_id = str(uuid.uuid4())
            values = {
                "schema_version": str(SCHEMA_VERSION),
                "repository_id": repository_id,
                "name": name or root_path.name,
                "current_branch": "main",
            }
            connection.executemany("INSERT INTO metadata(key, value) VALUES (?, ?)", values.items())
            connection.execute(
                "INSERT INTO refs(name, commit_hash, updated_at) VALUES (?, NULL, ?)",
                ("main", _now()),
            )
            connection.commit()
        finally:
            connection.close()
        repo = cls(root_path)
        repo.append_event(
            "repository.initialized",
            {"repository_id": repository_id, "name": name or root_path.name},
            actor=actor,
        )
        return repo

    @classmethod
    def discover(cls, start: Path | str = ".") -> Repository:
        current = Path(start).resolve()
        for candidate in (current, *current.parents):
            if (candidate / ".cvcs" / "ledger.db").is_file():
                return cls(candidate)
        raise NotARepositoryError(f"no .cvcs repository found from {current}")

    @classmethod
    def import_bundle(cls, root: Path | str, source: TextIOBase) -> Repository:
        """Create a repository from a canonical JSONL bundle."""
        records = cls._read_bundle(source)
        header = records[0]
        unknown = [
            record.get("record")
            for record in records[1:]
            if record.get("record") not in {"object", "event"}
        ]
        if unknown:
            raise IntegrityError(f"unknown bundle record type: {unknown[0]}")
        objects = [record for record in records[1:] if record.get("record") == "object"]
        events = [record for record in records[1:] if record.get("record") == "event"]
        cls._validate_bundle(header, objects, events)

        root_path = Path(root).resolve()
        control_dir = root_path / ".cvcs"
        database_path = control_dir / "ledger.db"
        if database_path.exists():
            raise ConflictError(f"CVCS repository already exists: {root_path}")
        control_dir.mkdir(parents=True, exist_ok=True)
        connection = sqlite3.connect(database_path)
        connection.row_factory = sqlite3.Row
        try:
            connection.executescript(SCHEMA)
            metadata = header["repository"]
            values = {
                "schema_version": str(SCHEMA_VERSION),
                "repository_id": metadata["id"],
                "name": metadata["name"],
                "current_branch": "main",
            }
            connection.executemany("INSERT INTO metadata(key, value) VALUES (?, ?)", values.items())
            connection.executemany(
                "INSERT INTO objects(hash, kind, body, created_at) VALUES (?, ?, ?, ?)",
                [
                    (
                        record["hash"],
                        record["kind"],
                        canonical_json(record["body"]),
                        record["created_at"],
                    )
                    for record in objects
                ],
            )
            connection.executemany(
                """INSERT INTO events(
                       sequence, id, type, timestamp, actor, payload, previous_hash, hash
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                [
                    (
                        record["sequence"],
                        record["id"],
                        record["type"],
                        record["timestamp"],
                        record["actor"],
                        canonical_json(record["payload"]),
                        record["previous_hash"],
                        record["hash"],
                    )
                    for record in events
                ],
            )
            cls._project_events(connection)
            connection.commit()
        except sqlite3.IntegrityError as exc:
            connection.rollback()
            connection.close()
            database_path.unlink(missing_ok=True)
            raise IntegrityError("bundle violates repository integrity") from exc
        except Exception:
            connection.rollback()
            connection.close()
            database_path.unlink(missing_ok=True)
            raise
        else:
            connection.close()
        repo = cls(root_path)
        repo.verify()
        return repo

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.database_path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        try:
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def metadata(self, key: str) -> str:
        with self.connect() as connection:
            row = connection.execute("SELECT value FROM metadata WHERE key = ?", (key,)).fetchone()
        if row is None:
            raise IntegrityError(f"missing repository metadata: {key}")
        return str(row["value"])

    @property
    def current_branch(self) -> str:
        return self.metadata("current_branch")

    def append_event(self, event_type: str, payload: Mapping[str, Any], *, actor: str) -> str:
        with self.connect() as connection:
            return self._append_event(connection, event_type, payload, actor=actor)

    def _append_event(
        self,
        connection: sqlite3.Connection,
        event_type: str,
        payload: Mapping[str, Any],
        *,
        actor: str,
    ) -> str:
        if not event_type or not actor:
            raise ValueError("event type and actor must be non-empty")
        previous = connection.execute(
            "SELECT hash FROM events ORDER BY sequence DESC LIMIT 1"
        ).fetchone()
        previous_hash = previous["hash"] if previous else None
        envelope = {
            "id": str(uuid.uuid4()),
            "type": event_type,
            "timestamp": _now(),
            "actor": actor,
            "payload": dict(payload),
            "previous_hash": previous_hash,
        }
        event_hash = digest(envelope)
        connection.execute(
            """INSERT INTO events(id, type, timestamp, actor, payload, previous_hash, hash)
               VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (
                envelope["id"],
                event_type,
                envelope["timestamp"],
                actor,
                canonical_json(payload),
                previous_hash,
                event_hash,
            ),
        )
        return event_hash

    def put_object(self, kind: str, body: Mapping[str, Any]) -> str:
        with self.connect() as connection:
            return self._put_object(connection, kind, body)

    @staticmethod
    def _put_object(
        connection: sqlite3.Connection, kind: str, body: Mapping[str, Any]
    ) -> str:
        value = {"kind": kind, "body": dict(body)}
        object_hash = digest(value)
        connection.execute(
            "INSERT OR IGNORE INTO objects(hash, kind, body, created_at) VALUES (?, ?, ?, ?)",
            (object_hash, kind, canonical_json(body), _now()),
        )
        return object_hash

    def object(self, object_hash: str) -> dict[str, Any]:
        with self.connect() as connection:
            row = connection.execute(
                "SELECT hash, kind, body, created_at FROM objects WHERE hash = ? OR hash LIKE ?",
                (object_hash, f"{object_hash}%"),
            ).fetchall()
        if len(row) != 1:
            label = "ambiguous" if row else "unknown"
            raise ConflictError(f"{label} object: {object_hash}")
        return {**dict(row[0]), "body": json.loads(row[0]["body"])}

    def head(self, branch: str | None = None) -> str | None:
        name = branch or self.current_branch
        with self.connect() as connection:
            row = connection.execute(
                "SELECT commit_hash FROM refs WHERE name = ?", (name,)
            ).fetchone()
        if row is None:
            raise ConflictError(f"unknown branch: {name}")
        return row["commit_hash"]

    def snapshot(self, commit_hash: str | None = None) -> dict[str, str]:
        resolved = commit_hash or self.head()
        if resolved is None:
            return {}
        obj = self.object(resolved)
        if obj["kind"] != "commit":
            raise IntegrityError(f"expected commit, got {obj['kind']}")
        return dict(obj["body"]["tree"])

    def resolve_revision(self, revision: str | None = None) -> str:
        """Resolve HEAD, a branch, or an unambiguous commit hash prefix."""
        if revision is None or revision == "HEAD":
            resolved = self.head()
            if resolved is None:
                raise ConflictError("HEAD has no commits")
            return resolved
        with self.connect() as connection:
            ref = connection.execute(
                "SELECT commit_hash FROM refs WHERE name = ?", (revision,)
            ).fetchone()
        if ref is not None:
            if ref["commit_hash"] is None:
                raise ConflictError(f"branch has no commits: {revision}")
            return str(ref["commit_hash"])
        obj = self.object(revision)
        if obj["kind"] != "commit":
            raise ConflictError(f"revision is not a commit: {revision}")
        return str(obj["hash"])

    def resolve_manifest(self, revision: str | None = None) -> dict[str, Any]:
        """Hydrate a commit into the provider-neutral input to an interpreter."""
        commit_hash = self.resolve_revision(revision)
        entries = []
        for path, blob_hash in sorted(self.snapshot(commit_hash).items()):
            blob = self.object(blob_hash)
            if blob["kind"] != "blob":
                raise IntegrityError(f"tree path {path} does not reference a blob")
            entries.append(
                {
                    "path": path,
                    "hash": blob["hash"],
                    "type": blob["body"]["type"],
                    "content": blob["body"]["content"],
                }
            )
        manifest = {
            "format_version": 1,
            "repository_id": self.metadata("repository_id"),
            "commit_hash": commit_hash,
            "entries": entries,
        }
        return {**manifest, "manifest_hash": digest(manifest)}

    def commit(
        self,
        changes: Mapping[str, tuple[str, Any] | None],
        *,
        message: str,
        actor: str,
    ) -> str:
        if not message.strip():
            raise ValueError("commit message must be non-empty")
        branch = self.current_branch
        parent = self.head(branch)
        tree = self.snapshot(parent)
        original_tree = dict(tree)
        change_summary: dict[str, str | None] = {}
        with self.connect() as connection:
            for path, change in sorted(changes.items()):
                self._validate_path(path)
                if change is None:
                    tree.pop(path, None)
                    change_summary[path] = None
                    continue
                kind, content = change
                blob_hash = self._put_object(
                    connection, "blob", {"type": kind, "content": content}
                )
                tree[path] = blob_hash
                change_summary[path] = blob_hash
            if parent is not None and tree == original_tree:
                raise ConflictError("nothing changed")
            commit_body = {
                "parent": parent,
                "tree": dict(sorted(tree.items())),
                "message": message.strip(),
                "actor": actor,
            }
            commit_hash = self._put_object(connection, "commit", commit_body)
            self._append_event(
                connection,
                "context.committed",
                {
                    "branch": branch,
                    "commit_hash": commit_hash,
                    "parent": parent,
                    "message": message.strip(),
                    "changes": change_summary,
                },
                actor=actor,
            )
            cursor = connection.execute(
                """UPDATE refs SET commit_hash = ?, updated_at = ?
                   WHERE name = ? AND commit_hash IS ?""",
                (commit_hash, _now(), branch, parent),
            )
            if cursor.rowcount != 1:
                raise ConflictError("branch advanced concurrently; retry the commit")
        return commit_hash

    def create_branch(self, name: str, *, actor: str) -> None:
        self._validate_ref(name)
        source_branch = self.current_branch
        head = self.head()
        with self.connect() as connection:
            try:
                connection.execute(
                    "INSERT INTO refs(name, commit_hash, updated_at) VALUES (?, ?, ?)",
                    (name, head, _now()),
                )
            except sqlite3.IntegrityError as exc:
                raise ConflictError(f"branch already exists: {name}") from exc
            self._append_event(
                connection,
                "branch.created",
                {"name": name, "from_branch": source_branch, "commit_hash": head},
                actor=actor,
            )

    def checkout(self, name: str, *, actor: str) -> None:
        self.head(name)
        old = self.current_branch
        with self.connect() as connection:
            connection.execute(
                "UPDATE metadata SET value = ? WHERE key = 'current_branch'", (name,)
            )
            self._append_event(
                connection, "branch.checked_out", {"from": old, "to": name}, actor=actor
            )

    def diff(self, base: str, compare: str) -> list[dict[str, str | None]]:
        base_tree = self.snapshot(base)
        compare_tree = self.snapshot(compare)
        result = []
        for path in sorted(base_tree.keys() | compare_tree.keys()):
            before, after = base_tree.get(path), compare_tree.get(path)
            if before == after:
                continue
            change = "added" if before is None else "removed" if after is None else "modified"
            result.append({"path": path, "change": change, "before": before, "after": after})
        return result

    def record_decision(
        self,
        *,
        decision_type: str,
        input_value: Any,
        output_value: Any,
        model: str,
        actor: str,
        metadata: Mapping[str, Any] | None = None,
        commit_hash: str | None = None,
        branch: str | None = None,
    ) -> str:
        resolved_commit = self.resolve_revision(commit_hash) if commit_hash else self.head()
        if resolved_commit is None:
            raise ConflictError("cannot record a decision before the first context commit")
        current_head = self.head()
        bound_branch = branch or (
            self.current_branch if resolved_commit == current_head else f"@{resolved_commit[:12]}"
        )
        decision_id = str(uuid.uuid4())
        recorded_at = _now()
        payload = {
            "decision_id": decision_id,
            "commit_hash": resolved_commit,
            "branch": bound_branch,
            "decision_type": decision_type,
            "input": input_value,
            "output": output_value,
            "model": model,
            "metadata": dict(metadata or {}),
        }
        with self.connect() as connection:
            event_hash = self._append_event(
                connection, "decision.recorded", payload, actor=actor
            )
            connection.execute(
                """INSERT INTO decisions(
                       id, commit_hash, branch, decision_type, input, output, model,
                       metadata, event_hash, recorded_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    decision_id,
                    resolved_commit,
                    bound_branch,
                    decision_type,
                    canonical_json(input_value),
                    canonical_json(output_value),
                    model,
                    canonical_json(metadata or {}),
                    event_hash,
                    recorded_at,
                ),
            )
        return decision_id

    def correct(
        self,
        decision_id: str,
        corrected_output: Any,
        *,
        actor: str,
        reason: str | None = None,
        scope: str = "output",
    ) -> str:
        if scope not in {"output", "partial", "routing", "policy"}:
            raise ValueError(f"invalid correction scope: {scope}")
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT id, output FROM decisions WHERE id = ? OR id LIKE ?",
                (decision_id, f"{decision_id}%"),
            ).fetchall()
        if len(rows) != 1:
            label = "ambiguous" if rows else "unknown"
            raise ConflictError(f"{label} decision: {decision_id}")
        resolved_id = rows[0]["id"]
        original = json.loads(rows[0]["output"])
        if original == corrected_output:
            raise ConflictError("corrected output is identical to the original")
        correction_id = str(uuid.uuid4())
        recorded_at = _now()
        payload = {
            "correction_id": correction_id,
            "decision_id": resolved_id,
            "original_output": original,
            "corrected_output": corrected_output,
            "reason": reason,
            "scope": scope,
        }
        with self.connect() as connection:
            event_hash = self._append_event(
                connection, "decision.corrected", payload, actor=actor
            )
            connection.execute(
                """INSERT INTO corrections(
                       id, decision_id, corrected_output, reason, scope, actor,
                       event_hash, recorded_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    correction_id,
                    resolved_id,
                    canonical_json(corrected_output),
                    reason,
                    scope,
                    actor,
                    event_hash,
                    recorded_at,
                ),
            )
        return correction_id

    def propose_rule(
        self,
        correction_ids: list[str],
        *,
        target_path: str,
        rule_content: Any,
        summary: str,
        actor: str,
        blob_type: str = "policy",
    ) -> str:
        """Turn correction evidence into a reviewable, inactive context proposal."""
        if not correction_ids:
            raise ValueError("a learning proposal requires correction evidence")
        if not summary.strip():
            raise ValueError("proposal summary must be non-empty")
        self._validate_path(target_path)
        resolved_evidence: list[str] = []
        with self.connect() as connection:
            for correction_id in correction_ids:
                rows = connection.execute(
                    "SELECT id FROM corrections WHERE id = ? OR id LIKE ?",
                    (correction_id, f"{correction_id}%"),
                ).fetchall()
                if len(rows) != 1:
                    label = "ambiguous" if rows else "unknown"
                    raise ConflictError(f"{label} correction: {correction_id}")
                resolved_evidence.append(str(rows[0]["id"]))
        proposal_id = str(uuid.uuid4())
        payload = {
            "proposal_id": proposal_id,
            "target_path": target_path,
            "blob_type": blob_type,
            "rule_content": rule_content,
            "evidence": sorted(set(resolved_evidence)),
            "summary": summary.strip(),
        }
        with self.connect() as connection:
            event_hash = self._append_event(
                connection, "learning.proposed", payload, actor=actor
            )
            connection.execute(
                """INSERT INTO learning_proposals(
                       id, target_path, blob_type, rule_content, evidence, summary, status,
                       proposed_by, proposed_event_hash, proposed_at
                   ) VALUES (?, ?, ?, ?, ?, ?, 'proposed', ?, ?, ?)""",
                (
                    proposal_id,
                    target_path,
                    blob_type,
                    canonical_json(rule_content),
                    canonical_json(payload["evidence"]),
                    summary.strip(),
                    actor,
                    event_hash,
                    _now(),
                ),
            )
        return proposal_id

    def proposal(self, proposal_id: str) -> dict[str, Any]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM learning_proposals WHERE id = ? OR id LIKE ?",
                (proposal_id, f"{proposal_id}%"),
            ).fetchall()
        if len(rows) != 1:
            label = "ambiguous" if rows else "unknown"
            raise ConflictError(f"{label} learning proposal: {proposal_id}")
        row = dict(rows[0])
        return {
            **row,
            "rule_content": json.loads(row["rule_content"]),
            "evidence": json.loads(row["evidence"]),
        }

    def ratify_rule(self, proposal_id: str, *, message: str, actor: str) -> str:
        """Approve a proposal and commit its rule into active cognition."""
        proposal = self.proposal(proposal_id)
        if proposal["status"] != "proposed":
            raise ConflictError(f"proposal is already {proposal['status']}: {proposal['id']}")
        commit_hash = self.commit(
            {
                proposal["target_path"]: (
                    proposal["blob_type"],
                    proposal["rule_content"],
                )
            },
            message=message,
            actor=actor,
        )
        payload = {
            "proposal_id": proposal["id"],
            "commit_hash": commit_hash,
            "target_path": proposal["target_path"],
            "evidence": proposal["evidence"],
        }
        with self.connect() as connection:
            event_hash = self._append_event(
                connection, "learning.ratified", payload, actor=actor
            )
            cursor = connection.execute(
                """UPDATE learning_proposals
                   SET status = 'ratified', ratified_commit_hash = ?,
                       ratified_event_hash = ?, ratified_at = ?
                   WHERE id = ? AND status = 'proposed'""",
                (commit_hash, event_hash, _now(), proposal["id"]),
            )
            if cursor.rowcount != 1:
                raise ConflictError("proposal was ratified concurrently")
        return commit_hash

    def learning_queue(self) -> list[dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                """SELECT * FROM learning_proposals
                   WHERE status = 'proposed' ORDER BY proposed_at"""
            ).fetchall()
        return [
            {
                **dict(row),
                "rule_content": json.loads(row["rule_content"]),
                "evidence": json.loads(row["evidence"]),
            }
            for row in rows
        ]

    def decision(self, decision_id: str) -> dict[str, Any]:
        with self.connect() as connection:
            rows = connection.execute(
                "SELECT * FROM decisions WHERE id = ? OR id LIKE ?",
                (decision_id, f"{decision_id}%"),
            ).fetchall()
        if len(rows) != 1:
            label = "ambiguous" if rows else "unknown"
            raise ConflictError(f"{label} decision: {decision_id}")
        row = dict(rows[0])
        return {
            **row,
            "input": json.loads(row["input"]),
            "output": json.loads(row["output"]),
            "metadata": json.loads(row["metadata"]),
        }

    def record_replay(
        self,
        decision_id: str,
        *,
        replay_commit_hash: str,
        model: str,
        output: Any,
        latency_ms: int | None,
        actor: str,
    ) -> dict[str, Any]:
        from cvcs.runtime import structural_diff

        original = self.decision(decision_id)
        resolved_commit = self.resolve_revision(replay_commit_hash)
        context_diff = self.diff(original["commit_hash"], resolved_commit)
        output_diff = structural_diff(original["output"], output)
        replay_id = str(uuid.uuid4())
        payload = {
            "replay_id": replay_id,
            "original_decision_id": original["id"],
            "original_commit_hash": original["commit_hash"],
            "replay_commit_hash": resolved_commit,
            "model": model,
            "output": output,
            "output_matches": not output_diff,
            "context_diff": context_diff,
            "output_diff": output_diff,
            "latency_ms": latency_ms,
        }
        with self.connect() as connection:
            event_hash = self._append_event(
                connection, "decision.replayed", payload, actor=actor
            )
            connection.execute(
                """INSERT INTO replays(
                       id, original_decision_id, original_commit_hash, replay_commit_hash,
                       model, output, output_matches, context_diff, output_diff, latency_ms,
                       event_hash, recorded_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    replay_id,
                    original["id"],
                    original["commit_hash"],
                    resolved_commit,
                    model,
                    canonical_json(output),
                    int(not output_diff),
                    canonical_json(context_diff),
                    canonical_json(output_diff),
                    latency_ms,
                    event_hash,
                    _now(),
                ),
            )
        return payload

    def events(self, *, limit: int | None = None) -> list[dict[str, Any]]:
        query = "SELECT * FROM events ORDER BY sequence DESC"
        parameters: tuple[Any, ...] = ()
        if limit is not None:
            query += " LIMIT ?"
            parameters = (limit,)
        with self.connect() as connection:
            rows = connection.execute(query, parameters).fetchall()
        return [{**dict(row), "payload": json.loads(row["payload"])} for row in rows]

    def correction_queue(self) -> list[dict[str, Any]]:
        with self.connect() as connection:
            rows = connection.execute(
                """SELECT c.id, c.decision_id, d.decision_type, c.reason, c.scope,
                          c.actor, c.recorded_at
                   FROM corrections c JOIN decisions d ON d.id = c.decision_id
                   ORDER BY c.recorded_at DESC"""
            ).fetchall()
        return [dict(row) for row in rows]

    def export_bundle(self, destination: TextIOBase) -> dict[str, int]:
        """Write the repository as deterministic, newline-delimited canonical JSON."""
        header = {
            "record": "cvcs.bundle",
            "format_version": BUNDLE_FORMAT_VERSION,
            "repository": {
                "id": self.metadata("repository_id"),
                "name": self.metadata("name"),
                "schema_version": int(self.metadata("schema_version")),
            },
        }
        destination.write(canonical_json(header) + "\n")
        with self.connect() as connection:
            objects = connection.execute("SELECT * FROM objects ORDER BY hash").fetchall()
            events = connection.execute("SELECT * FROM events ORDER BY sequence").fetchall()
        for row in objects:
            destination.write(
                canonical_json(
                    {
                        "record": "object",
                        "hash": row["hash"],
                        "kind": row["kind"],
                        "body": json.loads(row["body"]),
                        "created_at": row["created_at"],
                    }
                )
                + "\n"
            )
        for row in events:
            destination.write(
                canonical_json(
                    {
                        "record": "event",
                        "sequence": row["sequence"],
                        "id": row["id"],
                        "type": row["type"],
                        "timestamp": row["timestamp"],
                        "actor": row["actor"],
                        "payload": json.loads(row["payload"]),
                        "previous_hash": row["previous_hash"],
                        "hash": row["hash"],
                    }
                )
                + "\n"
            )
        return {"events": len(events), "objects": len(objects)}

    def rebuild_projections(self) -> dict[str, int]:
        """Discard and deterministically reconstruct query projections from events."""
        with self.connect() as connection:
            connection.execute("DELETE FROM learning_proposals")
            connection.execute("DELETE FROM replays")
            connection.execute("DELETE FROM corrections")
            connection.execute("DELETE FROM decisions")
            connection.execute("DELETE FROM refs")
            connection.execute(
                "UPDATE metadata SET value = 'main' WHERE key = 'current_branch'"
            )
            return self._project_events(connection)

    @staticmethod
    def _project_events(connection: sqlite3.Connection) -> dict[str, int]:
        counts = {
            "refs": 0,
            "decisions": 0,
            "corrections": 0,
            "replays": 0,
            "proposals": 0,
        }
        events = connection.execute("SELECT * FROM events ORDER BY sequence").fetchall()
        for event in events:
            payload = json.loads(event["payload"])
            if event["type"] == "repository.initialized":
                connection.execute(
                    "INSERT INTO refs(name, commit_hash, updated_at) VALUES ('main', NULL, ?)",
                    (event["timestamp"],),
                )
                counts["refs"] += 1
            elif event["type"] == "context.committed":
                cursor = connection.execute(
                    "UPDATE refs SET commit_hash = ?, updated_at = ? WHERE name = ?",
                    (payload["commit_hash"], event["timestamp"], payload["branch"]),
                )
                if cursor.rowcount != 1:
                    raise IntegrityError(
                        f"commit event references unknown branch: {payload['branch']}"
                    )
            elif event["type"] == "branch.created":
                connection.execute(
                    "INSERT INTO refs(name, commit_hash, updated_at) VALUES (?, ?, ?)",
                    (payload["name"], payload["commit_hash"], event["timestamp"]),
                )
                counts["refs"] += 1
            elif event["type"] == "branch.checked_out":
                connection.execute(
                    "UPDATE metadata SET value = ? WHERE key = 'current_branch'",
                    (payload["to"],),
                )
            elif event["type"] == "decision.recorded":
                connection.execute(
                    """INSERT INTO decisions(
                           id, commit_hash, branch, decision_type, input, output, model,
                           metadata, event_hash, recorded_at
                       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        payload["decision_id"],
                        payload["commit_hash"],
                        payload["branch"],
                        payload["decision_type"],
                        canonical_json(payload["input"]),
                        canonical_json(payload["output"]),
                        payload["model"],
                        canonical_json(payload.get("metadata", {})),
                        event["hash"],
                        event["timestamp"],
                    ),
                )
                counts["decisions"] += 1
            elif event["type"] == "decision.corrected":
                connection.execute(
                    """INSERT INTO corrections(
                           id, decision_id, corrected_output, reason, scope, actor,
                           event_hash, recorded_at
                       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        payload["correction_id"],
                        payload["decision_id"],
                        canonical_json(payload["corrected_output"]),
                        payload.get("reason"),
                        payload["scope"],
                        event["actor"],
                        event["hash"],
                        event["timestamp"],
                    ),
                )
                counts["corrections"] += 1
            elif event["type"] == "decision.replayed":
                connection.execute(
                    """INSERT INTO replays(
                           id, original_decision_id, original_commit_hash, replay_commit_hash,
                           model, output, output_matches, context_diff, output_diff, latency_ms,
                           event_hash, recorded_at
                       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        payload["replay_id"],
                        payload["original_decision_id"],
                        payload["original_commit_hash"],
                        payload["replay_commit_hash"],
                        payload["model"],
                        canonical_json(payload["output"]),
                        int(payload["output_matches"]),
                        canonical_json(payload["context_diff"]),
                        canonical_json(payload["output_diff"]),
                        payload.get("latency_ms"),
                        event["hash"],
                        event["timestamp"],
                    ),
                )
                counts["replays"] += 1
            elif event["type"] == "learning.proposed":
                connection.execute(
                    """INSERT INTO learning_proposals(
                           id, target_path, blob_type, rule_content, evidence, summary, status,
                           proposed_by, proposed_event_hash, proposed_at
                       ) VALUES (?, ?, ?, ?, ?, ?, 'proposed', ?, ?, ?)""",
                    (
                        payload["proposal_id"],
                        payload["target_path"],
                        payload["blob_type"],
                        canonical_json(payload["rule_content"]),
                        canonical_json(payload["evidence"]),
                        payload["summary"],
                        event["actor"],
                        event["hash"],
                        event["timestamp"],
                    ),
                )
                counts["proposals"] += 1
            elif event["type"] == "learning.ratified":
                cursor = connection.execute(
                    """UPDATE learning_proposals
                       SET status = 'ratified', ratified_commit_hash = ?,
                           ratified_event_hash = ?, ratified_at = ?
                       WHERE id = ? AND status = 'proposed'""",
                    (
                        payload["commit_hash"],
                        event["hash"],
                        event["timestamp"],
                        payload["proposal_id"],
                    ),
                )
                if cursor.rowcount != 1:
                    raise IntegrityError("ratification references an inactive proposal")
        return counts

    @staticmethod
    def _read_bundle(source: TextIOBase) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        for line_number, line in enumerate(source, start=1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise IntegrityError(f"invalid JSON at bundle line {line_number}") from exc
            if not isinstance(value, dict):
                raise IntegrityError(f"bundle line {line_number} is not an object")
            records.append(value)
        if not records:
            raise IntegrityError("bundle is empty")
        return records

    @staticmethod
    def _validate_bundle(
        header: dict[str, Any],
        objects: list[dict[str, Any]],
        events: list[dict[str, Any]],
    ) -> None:
        if header.get("record") != "cvcs.bundle":
            raise IntegrityError("first bundle record must be cvcs.bundle")
        if header.get("format_version") != BUNDLE_FORMAT_VERSION:
            raise IntegrityError(f"unsupported bundle format: {header.get('format_version')}")
        if not isinstance(header.get("repository"), dict):
            raise IntegrityError("bundle is missing repository metadata")
        repository = header["repository"]
        if not repository.get("id") or not repository.get("name"):
            raise IntegrityError("bundle has incomplete repository metadata")
        if not events or events[0].get("type") != "repository.initialized":
            raise IntegrityError("bundle must begin with repository.initialized")
        genesis = events[0].get("payload")
        if not isinstance(genesis, dict) or (
            genesis.get("repository_id") != repository["id"]
            or genesis.get("name") != repository["name"]
        ):
            raise IntegrityError("bundle header does not match repository genesis event")
        object_hashes = [record.get("hash") for record in objects]
        if len(object_hashes) != len(set(object_hashes)):
            raise IntegrityError("bundle contains duplicate objects")
        event_ids = [record.get("id") for record in events]
        if len(event_ids) != len(set(event_ids)):
            raise IntegrityError("bundle contains duplicate event IDs")
        for record in objects:
            expected = digest({"kind": record.get("kind"), "body": record.get("body")})
            if expected != record.get("hash"):
                raise IntegrityError(f"invalid object hash: {record.get('hash')}")
        object_map = {record["hash"]: record for record in objects}
        for record in objects:
            if record["kind"] != "commit":
                continue
            body = record.get("body")
            if not isinstance(body, dict) or not isinstance(body.get("tree"), dict):
                raise IntegrityError(f"invalid commit object: {record['hash']}")
            references = [*body["tree"].values()]
            if body.get("parent") is not None:
                references.append(body["parent"])
            missing = next((value for value in references if value not in object_map), None)
            if missing:
                raise IntegrityError(f"commit {record['hash']} references missing object {missing}")
        previous_hash: str | None = None
        for expected_sequence, record in enumerate(events, start=1):
            envelope = {
                "id": record.get("id"),
                "type": record.get("type"),
                "timestamp": record.get("timestamp"),
                "actor": record.get("actor"),
                "payload": record.get("payload"),
                "previous_hash": record.get("previous_hash"),
            }
            if record.get("sequence") != expected_sequence:
                raise IntegrityError(f"non-contiguous event sequence at {expected_sequence}")
            if record.get("previous_hash") != previous_hash or digest(envelope) != record.get(
                "hash"
            ):
                raise IntegrityError(f"event chain broken at sequence {expected_sequence}")
            previous_hash = record["hash"]

    def verify(self) -> dict[str, int]:
        previous_hash: str | None = None
        event_count = 0
        with self.connect() as connection:
            rows = connection.execute("SELECT * FROM events ORDER BY sequence").fetchall()
            object_rows = connection.execute("SELECT * FROM objects").fetchall()
        for row in rows:
            envelope = {
                "id": row["id"],
                "type": row["type"],
                "timestamp": row["timestamp"],
                "actor": row["actor"],
                "payload": json.loads(row["payload"]),
                "previous_hash": row["previous_hash"],
            }
            if row["previous_hash"] != previous_hash or digest(envelope) != row["hash"]:
                raise IntegrityError(f"event chain broken at sequence {row['sequence']}")
            previous_hash = row["hash"]
            event_count += 1
        for row in object_rows:
            if digest({"kind": row["kind"], "body": json.loads(row["body"])}) != row["hash"]:
                raise IntegrityError(f"content object failed verification: {row['hash']}")
        return {"events": event_count, "objects": len(object_rows)}

    @staticmethod
    def default_actor() -> str:
        return os.environ.get("CVCS_ACTOR") or os.environ.get("USER") or "unknown"

    @staticmethod
    def _validate_path(path: str) -> None:
        if not path or path.startswith("/") or ".." in Path(path).parts:
            raise ValueError(f"invalid context path: {path}")

    @staticmethod
    def _validate_ref(name: str) -> None:
        allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.")
        if not name or name.startswith("/") or name.endswith("/") or set(name) - allowed:
            raise ValueError(f"invalid branch name: {name}")
