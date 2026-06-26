# CVCS

**Cognitive Version Control System**

Every AI system today produces decisions. Yet nobody treats those decisions as versioned artifacts that you can own, branch, replay, and merge. The context that shaped each decision, including the prompt, the active policy, the available knowledge, and the model that ran, disappears the moment the request ends.

This is not an observability problem. Observability tools log what happened. CVCS versions why it happened, making it possible to replay it, diff it, branch from it, and own it, independent of which vendor's model is currently running.

The distinction matters:

```
Observability   ->  "what did it do?"
CVCS            ->  "what did it know, and can I reproduce that exact cognition later?"
```

---

## The Formalism

```
Identity = Log × Interpreter
```

An AI agent's identity does not live in its model weights. The model is rented. What you own is the accumulated history: every decision, correction, and context change that shapes how the system behaves in your domain. That history is the asset.

This has one practical consequence that is easy to miss:

> If your agent breaks when you swap GPT-4 for Claude, you built it wrong. All identity work that cannot live in the weights must live in the log. The log is the only artifact you fully own.

The model is a runtime. The log is the system.

```
Same log + new model    = upgrade, not replacement
Same log + new branch   = safe experiment
Same log + replay       = full audit, years later
Two logs + merge        = organizations sharing what they learned
```

---

## What This Solves

Modern AI deployments have no durable memory of themselves:

- Which prompt produced this decision last Tuesday?
- Did behavior change because we updated the policy, or because the model changed?
- Can I replay this exact decision against the new model to measure the drift?
- The insurance team learned something. Can the underwriting team inherit that learning without starting over?
- If we leave OpenAI tomorrow, do we lose three years of behavioral history?

CVCS answers all of these by treating every cognitive state as a commit, every decision as a ledger entry, and every correction as a first-class learning event.

---

## What Corrections Actually Are

When a human overrides an AI decision:

```
AI  -> output A
Human -> output B
```

That is not noise. It is institutional knowledge surfacing. Every recurring correction exposes a rule that existed long before anyone bothered to document it. The richest source of organizational knowledge is not your documentation. It is the pattern of repeated corrections.

CVCS captures every correction as an immutable event linked to the exact decision it replaced. Over time, those events become the organization's real memory. Not the process it claimed to follow, but the one it actually did.

---

## What It Does

1. **Commits.** Every change to cognitive context, including prompts, policies, knowledge, and workflows, creates an immutable, content-addressed commit. Nothing is overwritten. History is append-only.

2. **Branches.** Create isolated cognitive timelines. Experiment freely without affecting production. Compare outcomes before merging.

3. **Replay.** Re-execute any historical decision against any commit or interpreter(model). See what changed and why.

4. **Diff.** Compare any two cognitive states. Surface changes in prompts, policies, knowledge, behavior, and outcomes in plain language.

5. **Merge.** Combine changes from independent branches into a single history. Organizational knowledge evolves only through explicit approval.

6. **Rollback.** Move the branch pointer to any previous commit. The history remains intact. Only the active state changes.


---

## What Users Actually Do

```bash
cvcs commit --message "tightened credit approval policy"
cvcs branch experiment/looser-sku-matching
cvcs replay decision abc123 --commit HEAD --model claude-sonnet-4-6
cvcs diff main..experiment/looser-sku-matching
cvcs merge experiment/looser-sku-matching --require-approval
cvcs rollback commit def456
```

---

## Architecture

```
CLI / API
  commit | branch | replay | diff | merge | rollback
                      |
         Cognitive Runtime Engine
    Load commit → hydrate context → call model → audit result
                      |
         ┌────────────┴─────────────────┐
         │       Postgres Ledger        │
         │                              │
         │  [1] repositories            │  namespace / tenant boundary
         │  [2] content store           │  blobs, commits, trees
         │  [3] execution ledger        │  decisions, replays
         │  [4] correction layer        │  human overrides, learning signal
         │  [5] collaboration layer     │  branches, merge requests
         └──────────────────────────────┘
                      |
         Swappable Model Layer
    OpenAI | Anthropic | Llama | Local
```

Postgres is the ledger. The model is a runtime detail.

---

## Schema Files

```
schema/
  01_repositories.sql   — namespace, tenant isolation, bootstrap
  02_content_store.sql  — blobs, commits, trees (the git object model)
  03_execution.sql      — decisions, replays (runtime events, immutable)
  04_corrections.sql    — human overrides, the learning signal
  05_collaboration.sql  — branches, merge requests, approval flow
```

## MVP Stack

- **Storage:** Postgres. No adapters. No multi-database abstraction for MVP. The ledger semantics (append-only triggers, content-addressed hashing, referential integrity) are Postgres-native and that is not incidental.
- **Backend:** Go. The runtime engine that loads commits, hydrates context, calls models, and writes to the ledger.
- **Frontend:** TypeScript. The UI surface: diff viewer, replay inspector, branch graph.
- **Models:** Any HTTP API. The runtime engine holds a thin interface. Swap the implementation, not the architecture.

---

## What This Is Not

Not a prompt management tool. Not an observability dashboard. Not a RAG pipeline. Not an eval harness.

Those tools answer "what happened?" CVCS answers "what did the system *know* when it decided and can I own, reproduce, and evolve that knowledge independently of my vendors?"

This is version control for how organizations think and decide over time.