# CVCS

**Version control for AI cognition and context.**

AI systems accumulate identity outside their model weights: prompts, policies, tool
contracts, corrections, exceptions, and the decisions that made those things necessary.
Today that history is scattered across application databases, tracing vendors, prompt
dashboards, and people's heads. Change the model or orchestration framework and much of
the system's learned behavior disappears.

CVCS makes that history an owned, portable artifact.

```text
agent identity = cognitive log x interpreter
```

The interpreter is the model and agent loop. It is replaceable. The cognitive log is the
accumulated organizational knowledge that should survive every runtime change.

## The loop

```text
context commit -> decision -> correction -> reviewed rule -> context commit
       ^                                                       |
       +-------------------------------------------------------+
```

A human override is not merely an error metric. It is evidence that an undocumented rule,
exception, or preference exists. CVCS preserves that evidence against the exact cognitive
state and runtime that produced the original decision. Repeated corrections can then be
proposed as rules, reviewed, and committed back into future context.

CVCS is therefore more than prompt versioning and more than observability:

```text
observability: what did the runtime do?
CVCS:          what did it know, what corrected it, and how did that change what came next?
```

## Try the executable kernel

CVCS currently ships a local-first Python kernel. It requires Python 3.12+ and
[`uv`](https://docs.astral.sh/uv/).

```bash
uv sync
uv run cvcs init demo --name claims-agent
cd demo

uv run cvcs commit prompts/system \
  "You triage insurance claims." \
  --type prompt \
  --message "establish agent role"

uv run cvcs commit policies/high-value \
  '{"review_above": 10000}' \
  --type policy \
  --message "require human review for high-value claims"

uv run cvcs decision claim_triage \
  --input '{"amount": 15000}' \
  --output '{"route": "automatic"}' \
  --model example/model-v1

uv run cvcs correct <decision-id> \
  --output '{"route": "human_review"}' \
  --scope policy \
  --reason "High-value claims require review"

uv run cvcs queue
uv run cvcs log
uv run cvcs verify

# Move the complete cognitive history to another machine or runtime
uv run cvcs export claims-agent.cvcs.jsonl
uv run cvcs import claims-agent.cvcs.jsonl ../restored-claims-agent
```

Run the correction-to-replay demonstration:

```bash
uv run python examples/claims_demo.py
```

It records a real claims-routing decision under a stale `25000` review policy, captures a
supervisor correction, creates an inactive evidence-backed rule proposal, ratifies the
`10000` policy on a learning branch, and replays the exact historical input. The result
contains both the changed cognitive paths and the structural output differences.

Any executable can act as an interpreter. It receives a JSON object containing
`decision_type`, `input`, and the resolved cognitive `manifest` on stdin, and returns one
JSON value on stdout:

```bash
uv run cvcs run claim_routing \
  --input '{"claim_id":"CLM-1042","amount":15000}' \
  --model internal/claims-v1 \
  --command python examples/claims_runtime.py

uv run cvcs replay <decision-id> \
  --commit learning/lower-review-threshold \
  --model internal/claims-v1 \
  --command python examples/claims_runtime.py
```

`--model` is recorded identity, not a provider integration requirement. The command can
wrap an HTTP model API, an agent framework, a local model, or deterministic business code.

Set `CVCS_ACTOR` to put a stable human or service identity on every event. `--actor` takes
precedence for a single command.

## Commands

| Command | Purpose |
| --- | --- |
| `cvcs init` | Create `.cvcs/ledger.db` and the genesis event |
| `cvcs commit` | Put a prompt, policy, tool, workflow, or knowledge value at a logical path |
| `cvcs remove` | Remove a path through a new immutable commit |
| `cvcs branch` / `checkout` | Fork and select cognitive timelines |
| `cvcs decision` | Bind a runtime decision to the exact active commit |
| `cvcs correct` | Preserve a human override as a first-class learning event |
| `cvcs queue` | Show correction evidence waiting to be turned into context |
| `cvcs propose-rule` | Turn one or more corrections into an inactive rule proposal |
| `cvcs learning` | Show proposals waiting for human ratification |
| `cvcs ratify-rule` | Approve a proposal and generate its context commit |
| `cvcs diff` / `show` / `log` | Inspect state, objects, and causal history |
| `cvcs resolve` | Hydrate a commit into a provider-neutral runtime manifest |
| `cvcs run` | Execute an external interpreter and record its decision at that manifest |
| `cvcs replay` | Re-run an actual historical input against another commit or interpreter |
| `cvcs export` / `import` | Move a canonical, vendor-neutral cognitive history |
| `cvcs rebuild` | Reconstruct query projections deterministically from the event log |
| `cvcs verify` | Recompute every event and object hash |

## Storage model

The repository is a small, portable directory:

```text
.cvcs/
  ledger.db
```

The SQLite ledger contains:

- an append-only, SHA-256-chained cognitive event stream;
- content-addressed blobs and commits;
- branch pointers;
- query projections for decisions, corrections, proposals, ratifications, and replays.

The event stream is the source of truth. Projections exist to make the history useful.
Read [the architecture note](docs/architecture.md) for the boundary between the ledger,
the cognition graph, and replaceable runtimes.

### Portable bundle format

`cvcs export` emits canonical JSON Lines. The first record identifies the format and
repository, followed by content-addressed objects and the ordered event chain. Mutable
SQLite projections are intentionally excluded. During import, CVCS validates every object
hash and every link in the event chain before rebuilding branch refs, decisions, and
corrections.

This makes the bundle an interoperability boundary rather than a database backup. Another
implementation can consume it without reproducing CVCS's SQLite layout.

The ordered Postgres modules under [`schema/postgres/`](schema/postgres/) define the
collaborative/server model.
It covers repositories, content, executions, corrections, ratified rules, branches, and
merge review. The local kernel lets the semantics mature through use before a networked
control plane freezes them.

## Principles

- **The model is a runtime.** Provider SDK objects never define stored identity.
- **Corrections are knowledge evidence.** They remain linked to the decision and context
  they corrected.
- **Learning is governed.** Detected patterns become active rules only through explicit
  review and a new commit.
- **History is append-only.** State changes by adding facts and moving refs, not rewriting
  evidence.
- **Portability is architectural.** Canonical JSON and content hashes are stable across
  languages, databases, and vendors.

## Why this is not an eval platform

An eval starts with a dataset and asks how a model scores. CVCS starts with an actual
decision and asks which owned cognitive state produced it, what a human corrected, which
governed change followed, and whether replaying that same input changes the outcome.

Evals can consume CVCS history, but they are downstream. CVCS owns the causal record that
explains *why* behavior changed across prompts, policies, tools, knowledge, workflows, and
interpreters.

## Maturity

CVCS is an alpha kernel that proves the complete cognitive learning loop. It is not yet a
secure multi-tenant control plane. The missing security, distributed-systems, governance,
and operational work is explicit in [production readiness](docs/production-readiness.md),
with a ready-to-publish [GitHub issue draft](docs/issues/001-production-control-plane.md).

## Development

```bash
uv sync --dev
uv run pytest
uv run ruff check .
```

Open source under the MIT License.
