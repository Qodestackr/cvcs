# Architecture: the agent is the log

CVCS is an event-sourced control plane for AI behavior. It is not the agent runtime.
The runtime can be OpenAI, Anthropic, a local model, or ordinary deterministic code.
CVCS owns the state that must survive replacing that runtime.

## The unit of value

The durable asset is a chained sequence of facts:

```text
context committed
  -> decision recorded
  -> human correction recorded
  -> correction pattern proposed
  -> rule ratified
  -> context committed
  -> future decision
```

The much-discussed “agent loop” is an interpreter repeatedly consuming this log and
emitting new events. The loop is replaceable. The accumulated, reviewed history is not.

## Three layers

1. **Event ledger (source of truth).** Every state transition is an immutable event whose
   hash includes the preceding event hash. This gives CVCS a portable, tamper-evident
   history.
2. **Content-addressed cognition.** Prompts, policies, tool contracts, knowledge, and
   workflows are blobs. A commit maps stable logical paths to exact blob hashes.
3. **Projections and runtimes.** SQLite is the local projection. Postgres is the intended
   collaborative/server projection. Model adapters consume a commit and record their
   result; they never own agent identity.

## What is deliberately not automatic

A correction is evidence, not immediately a new rule. Turning repeated corrections into
active context crosses a governance boundary:

```text
observed correction -> proposed pattern -> human review -> ratified rule -> commit
```

Automating the first arrow is useful. Automating the review away would turn incidental
operator behavior, attacks, and one-off exceptions into permanent organizational policy.

## Local-first now, server later

The first executable version stores `.cvcs/ledger.db` beside a project. It uses only the
Python standard library, so the core works without a database service or model API. A
canonical JSONL bundle carries content-addressed objects plus the cryptographically linked
event sequence; branches, decisions, corrections, and replays are rebuilt projections
rather than database-specific state. The ordered Postgres modules in `schema/postgres/`
remain the design for
multi-user projections, policy enforcement, and review workflows.

## Near-term roadmap

1. Define explicit precedence and composition semantics between resolved prompt, policy,
   tool, knowledge, workflow, and context entries.
2. Add HTTP and provider adapters behind the command-runtime contract.
3. Cluster corrections into proposed rules with traceable supporting decision IDs.
4. Add signed events, tenant keys, and a Postgres projector for collaborative operation.
