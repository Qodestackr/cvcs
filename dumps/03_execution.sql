-- ============================================================
-- The runtime ledger. Every AI execution is recorded here.
-- Two tables:
--
--   decisions = every model call, tied to the exact commit
--   replays   = re-executions of historical decisions
--
-- The foreign key decision.commit_id is the entire point.
-- Without it, replay is theater. With it, replay is proof.
-- ============================================================

-- ============================================================
-- DECISIONS
--
-- Every AI execution is a decision. Immutable on insert.
-- Tied to the exact commit that was active when it ran.
--
-- prompt_path is the path inside the commit tree that was
-- used as the primary prompt. e.g. "prompts/credit_check/system"
-- This lets you know exactly which blob drove the output.
--
-- input_hash is sha256(raw_input). Used to group identical
-- inputs across decisions and detect behavioral drift when
-- the same input produces different outputs over time.
-- ============================================================

CREATE TABLE cvcs.decisions (
  id                uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id     uuid             NOT NULL REFERENCES cvcs.repositories(id),
  commit_id         uuid             NOT NULL REFERENCES cvcs.commits(id),
  branch_id         uuid             REFERENCES cvcs.branches(id),

  -- what kind of decision
  decision_type     text             NOT NULL,

  -- the input
  input_hash        text             NOT NULL,
  raw_input         text             NOT NULL,

  -- the output
  raw_output        text             NOT NULL,

  -- which model ran
  model_id          text             NOT NULL,
  model_version     text,

  -- which prompt path inside the commit drove this
  prompt_path       text             NOT NULL,

  -- calibration
  confidence        double precision,
  latency_ms        integer,

  -- arbitrary runtime metadata
  -- use for: session_id, user_id, external_request_id, environment
  metadata          jsonb            NOT NULL DEFAULT '{}',

  decided_at        timestamptz      NOT NULL DEFAULT now(),

  CHECK (length(decision_type) > 0),
  CHECK (length(input_hash) = 64),
  CHECK (length(raw_input) > 0),
  CHECK (length(raw_output) > 0),
  CHECK (length(model_id) > 0),
  CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  CHECK (latency_ms IS NULL OR latency_ms >= 0)
);

CREATE INDEX decisions_commit_idx        ON cvcs.decisions (commit_id, decided_at DESC);
CREATE INDEX decisions_repository_idx    ON cvcs.decisions (repository_id, decided_at DESC);
CREATE INDEX decisions_input_hash_idx    ON cvcs.decisions (input_hash);
CREATE INDEX decisions_type_idx          ON cvcs.decisions (repository_id, decision_type, decided_at DESC);
CREATE INDEX decisions_model_idx         ON cvcs.decisions (model_id, decided_at DESC);
CREATE INDEX decisions_branch_idx        ON cvcs.decisions (branch_id, decided_at DESC) WHERE branch_id IS NOT NULL;

COMMENT ON TABLE cvcs.decisions IS
  'Every AI execution tied to the exact commit active when it ran. The commit_id foreign key is what makes replay meaningful rather than theatrical.';

COMMENT ON COLUMN cvcs.decisions.commit_id IS
  'The cognitive state that produced this output. Replay = re-run raw_input against any other commit_id and compare.';

COMMENT ON COLUMN cvcs.decisions.input_hash IS
  'sha256(raw_input). Groups identical inputs across decisions. Behavioral drift = same input_hash, different raw_output over time.';

COMMENT ON COLUMN cvcs.decisions.prompt_path IS
  'The path inside the commit tree used as the primary prompt. e.g. prompts/credit_check/system. Resolves to a blob via cvcs.trees.';

COMMENT ON COLUMN cvcs.decisions.model_id IS
  'The model identifier as passed to the provider API. e.g. claude-sonnet-4-6, gpt-4o, llama3. Stored verbatim.';

COMMENT ON COLUMN cvcs.decisions.confidence IS
  'Caller-supplied confidence score for the decision. Normalized to [0,1]. Used for calibration and drift detection.';

-- ============================================================
-- REPLAYS
--
-- Re-executions of historical decisions against a different
-- commit or model. This is how you answer:
--
--   "If we had used the updated policy last week, would this
--    decision have changed?"
--
--   "Does the new model produce different outputs than the
--    old model on our real historical inputs?"
--
-- output_matches = (raw_output == original raw_output)
-- divergence_summary = plain language description of what changed
-- Both are written by the runtime after comparing outputs.
-- ============================================================

CREATE TABLE cvcs.replays (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id         uuid        NOT NULL REFERENCES cvcs.repositories(id),
  original_decision_id  uuid        NOT NULL REFERENCES cvcs.decisions(id),

  -- what we replayed against
  replay_commit_id      uuid        NOT NULL REFERENCES cvcs.commits(id),
  replay_model_id       text        NOT NULL,

  -- what came back
  raw_output            text        NOT NULL,
  output_matches        boolean     NOT NULL,
  divergence_summary    text,

  -- who triggered this
  triggered_by          text,
  metadata              jsonb       NOT NULL DEFAULT '{}',

  replayed_at           timestamptz NOT NULL DEFAULT now(),

  CHECK (length(replay_model_id) > 0),
  CHECK (length(raw_output) > 0),
  CHECK (output_matches = false OR divergence_summary IS NULL)
);

CREATE INDEX replays_original_idx    ON cvcs.replays (original_decision_id, replayed_at DESC);
CREATE INDEX replays_commit_idx      ON cvcs.replays (replay_commit_id, replayed_at DESC);
CREATE INDEX replays_repository_idx  ON cvcs.replays (repository_id, replayed_at DESC);
CREATE INDEX replays_diverged_idx    ON cvcs.replays (repository_id, replayed_at DESC) WHERE output_matches = false;

COMMENT ON TABLE cvcs.replays IS
  'Re-executions of historical decisions against different commits or models. How you measure drift and validate upgrades before shipping them.';

COMMENT ON COLUMN cvcs.replays.original_decision_id IS
  'The decision being replayed. The runtime uses cvcs.replay_context() to hydrate everything needed from this id.';

COMMENT ON COLUMN cvcs.replays.replay_commit_id IS
  'The cognitive state used for the replay. Can be the same as the original or any other commit in the repo.';

COMMENT ON COLUMN cvcs.replays.output_matches IS
  'True if raw_output is semantically identical to the original. Exact string match for structured output. Embedding similarity for prose. Runtime decides.';

COMMENT ON COLUMN cvcs.replays.divergence_summary IS
  'Plain language description of what changed. Null when output_matches is true. Written by the runtime diff renderer.';

-- ============================================================
-- APPEND-ONLY ENFORCEMENT
-- ============================================================

CREATE TRIGGER decisions_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.decisions
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

CREATE TRIGGER replays_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.replays
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

-- ============================================================
-- REPLAY CONTEXT HELPER
--
-- Everything the runtime needs to replay a decision.
-- One call. No joins in application code.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.replay_context(p_decision_id uuid)
RETURNS TABLE (
  decision_id      uuid,
  commit_hash      text,
  commit_id        uuid,
  model_id         text,
  prompt_path      text,
  prompt_content   jsonb,
  full_context     jsonb,
  raw_input        text,
  raw_output       text,
  decided_at       timestamptz
)
LANGUAGE sql STABLE AS $$
  SELECT
    d.id                                                          AS decision_id,
    c.hash                                                        AS commit_hash,
    c.id                                                          AS commit_id,
    d.model_id,
    d.prompt_path,
    b.content                                                     AS prompt_content,
    (
      SELECT jsonb_object_agg(t.path, jsonb_build_object(
        'blob_hash', t.blob_hash,
        'blob_type', bl.blob_type,
        'content',   bl.content
      ))
      FROM cvcs.trees t
      JOIN cvcs.blobs bl ON bl.hash = t.blob_hash
      WHERE t.commit_id = d.commit_id
    )                                                             AS full_context,
    d.raw_input,
    d.raw_output,
    d.decided_at
  FROM cvcs.decisions d
  JOIN cvcs.commits c        ON c.id = d.commit_id
  JOIN cvcs.trees   t        ON t.commit_id = d.commit_id AND t.path = d.prompt_path
  JOIN cvcs.blobs   b        ON b.hash = t.blob_hash
  WHERE d.id = p_decision_id
$$;

COMMENT ON FUNCTION cvcs.replay_context IS
  'Everything the runtime needs to replay a decision: commit hash, model, prompt blob, full cognitive context, original input and output. One call.';

-- ============================================================
-- DRIFT DETECTION HELPER
--
-- Given a repository and time window, finds inputs that
-- produced different outputs across decisions over time.
-- These are the behavioral drift candidates.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.detect_drift(
  p_repository_id uuid,
  p_since         timestamptz DEFAULT now() - interval '30 days'
)
RETURNS TABLE (
  input_hash       text,
  decision_count   bigint,
  distinct_outputs bigint,
  first_seen       timestamptz,
  last_seen        timestamptz,
  model_ids        text[]
)
LANGUAGE sql STABLE AS $$
  SELECT
    input_hash,
    count(*)                                   AS decision_count,
    count(DISTINCT raw_output)                 AS distinct_outputs,
    min(decided_at)                            AS first_seen,
    max(decided_at)                            AS last_seen,
    array_agg(DISTINCT model_id ORDER BY model_id) AS model_ids
  FROM cvcs.decisions
  WHERE repository_id = p_repository_id
    AND decided_at >= p_since
  GROUP BY input_hash
  HAVING count(DISTINCT raw_output) > 1
  ORDER BY distinct_outputs DESC, decision_count DESC
$$;

COMMENT ON FUNCTION cvcs.detect_drift IS
  'Finds inputs that produced different outputs over the time window. Drift candidates: same input_hash, multiple distinct raw_outputs. Feed into replay to isolate whether the cause was a commit change or a model change.';
