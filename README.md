# CVCS

**Cognitive Version Control System**

Git versions code. CVCS versions cognition.

Every policy, prompt, decision, and correction an AI system makes is a fact. CVCS treats those facts as first-class artifacts: immutable, addressable, replayable, and branchable. The model is swappable. The accumulated context is yours.

---

## The Problem

Modern AI systems have no memory of themselves.

- Which prompt produced this decision?
- Which policy was active when the agent changed behavior?
- Why did it answer differently last Tuesday?
- Can I replay the exact execution against a new model?
- Can I merge what the sales team learned with what ops learned?

Most AI systems cannot answer these questions reliably. The context that made the decision is gone the moment the request ends.

---

## The Idea

AI agents do not live in their models. Models are rented. The agent lives in its accumulated history: the sequence of observations, decisions, corrections, and outcomes that define its behavior over time.

CVCS makes that history ownable.

```
Identity = Log x Interpreter

Same log + new model    = upgrade, not replacement
Same log + new branch   = experiment without risk
Same log + replay       = full audit, years later
Two logs + merge        = shared organizational learning
```

---

## What It Does

**Commits.** Every change to context (policy, prompt, knowledge, workflow) produces an immutable, content-addressed commit. Nothing is overwritten.

**Branches.** Experiment with a new policy without touching production. Compare two cognitive branches side by side before merging.

**Replay.** Execute any historical commit against any model. Deterministic. Auditable. Explainable.

**Diff.** See what changed between two cognitive states in plain language, not just raw JSON.

**Merge.** Combine learnings from separate branches with conflict detection and human approval required before organizational knowledge evolves.

**Rollback.** Restore any previous cognitive state in one operation.

---

## What Users Actually Do

```
cvcs commit --message "tightened credit approval policy"
cvcs branch experiment/looser-sku-matching
cvcs replay decision abc123 --model claude-sonnet-4-6
cvcs diff main..experiment/looser-sku-matching
cvcs merge experiment/looser-sku-matching --require-approval
cvcs rollback commit def456
```

---

## Architecture

```
User Interface / CLI
  compare  |  replay  |  rollback  |  diff  |  merge
                        |
          Cognitive Runtime Engine
   Load Commit -> Hydrate Context -> Execute AI -> Audit
                        |
         Postgres Cognitive Ledger
   Commits, Branches, Blobs, Policies, Decision Logs
                        |
         Swappable AI Model Layer
   OpenAI  |  Anthropic  |  Llama  |  Local
```

Postgres is the ledger. The model is a runtime detail.

---

## What This Is Not

Not a prompt management tool. Not an observability dashboard. Not a RAG framework.

This is version control for how organizations think and decide over time.
