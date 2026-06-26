-- ============================================================
-- The learning signal layer.
--
-- When a human overrides an AI decision:
--
--   AI     -> output A
--   Human  -> output B
--
-- That is not noise. That is institutional knowledge surfacing.
-- Every recurring correction reveals a rule that existed long
-- before anyone bothered to write it down.
--
-- This file captures every correction as an immutable event
-- linked to the exact decision it replaced. The original
-- decision is never touched. Both facts coexist in the ledger
-- permanently.
--
-- Over time the corrections table becomes the organization's
-- real memory: not the process it claimed to follow,
-- but the one it actually did.
-- ============================================================

-- ============================================================
-- CORRECTIONS
--
-- One row per human override. Append-only forever.
-- The original decision is referenced, never mutated.
--
-- produced_commit_id is set when a correction was significant
-- enough that the operator committed a new cognitive state in
-- response. This is the loop closing: correction -> new commit
-- -> better decisions -> fewer corrections.
--
-- pattern_key is an optional caller-supplied grouping key.
-- Use it to bucket corrections by type so the runtime can
-- surface recurring patterns. e.g. "sku_resolution_wrong_brand"
-- ============================================================

CREATE TABLE cvcs.corrections (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id       uuid        NOT NULL REFERENCES cvcs.repositories(id),
  decision_id         uuid        NOT NULL REFERENCES cvcs.decisions(id),

  -- who corrected it
  corrected_by        text        NOT NULL,

  -- what the AI said vs what the human chose
  original_output     text        NOT NULL,
  corrected_output    text        NOT NULL,

  -- why
  reason              text,

  -- optional: the correction category for pattern detection
  -- caller-supplied, free-form but should be consistent
  -- e.g. "wrong_sku", "wrong_threshold", "missing_context"
  pattern_key         text,

  -- if this correction led to a new commit, link it
  produced_commit_id  uuid        REFERENCES cvcs.commits(id),

  corrected_at        timestamptz NOT NULL DEFAULT now(),

  CHECK (length(corrected_by) > 0),
  CHECK (length(original_output) > 0),
  CHECK (length(corrected_output) > 0),
  CHECK (original_output <> corrected_output)
);

CREATE INDEX corrections_decision_idx     ON cvcs.corrections (decision_id);
CREATE INDEX corrections_repository_idx   ON cvcs.corrections (repository_id, corrected_at DESC);
CREATE INDEX corrections_pattern_idx      ON cvcs.corrections (repository_id, pattern_key, corrected_at DESC) WHERE pattern_key IS NOT NULL;
CREATE INDEX corrections_commit_idx       ON cvcs.corrections (produced_commit_id) WHERE produced_commit_id IS NOT NULL;
CREATE INDEX corrections_unclosed_idx     ON cvcs.corrections (repository_id, corrected_at DESC) WHERE produced_commit_id IS NULL;

COMMENT ON TABLE cvcs.corrections IS
  'Human overrides of AI decisions. The highest-signal learning event in the system. Append-only. The original decision is never mutated.';

COMMENT ON COLUMN cvcs.corrections.decision_id IS
  'The exact decision being overridden. Never updated. Both the original decision and this correction coexist permanently.';

COMMENT ON COLUMN cvcs.corrections.pattern_key IS
  'Optional caller-supplied grouping key. Use consistently to enable pattern detection across corrections. e.g. wrong_sku, wrong_threshold, missing_context.';

COMMENT ON COLUMN cvcs.corrections.produced_commit_id IS
  'Set when this correction was significant enough to produce a new cognitive state. The learning loop made visible: correction -> commit -> fewer corrections.';

COMMENT ON COLUMN cvcs.corrections.original_output IS
  'Copied from decisions.raw_output at insert time. Preserved here so the correction is self-contained even if query patterns change.';

-- ============================================================
-- APPEND-ONLY ENFORCEMENT
-- ============================================================

CREATE TRIGGER corrections_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.corrections
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

-- ============================================================
-- PATTERN DETECTION HELPER
--
-- Surfaces recurring correction patterns in a repository.
-- The highest-count pattern_keys are where the cognitive state
-- most needs to evolve. Feed into the merge/commit workflow
-- to close the loop.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.correction_patterns(
  p_repository_id uuid,
  p_since         timestamptz DEFAULT now() - interval '30 days',
  p_min_count     integer     DEFAULT 3
)
RETURNS TABLE (
  pattern_key          text,
  correction_count     bigint,
  unclosed_count       bigint,
  first_seen           timestamptz,
  last_seen            timestamptz,
  affected_decisions   bigint,
  example_decision_id  uuid,
  example_reason       text
)
LANGUAGE sql STABLE AS $$
  SELECT
    pattern_key,
    count(*)                                          AS correction_count,
    count(*) FILTER (WHERE produced_commit_id IS NULL) AS unclosed_count,
    min(corrected_at)                                 AS first_seen,
    max(corrected_at)                                 AS last_seen,
    count(DISTINCT decision_id)                       AS affected_decisions,
    (array_agg(decision_id ORDER BY corrected_at DESC))[1] AS example_decision_id,
    (array_agg(reason     ORDER BY corrected_at DESC))[1] AS example_reason
  FROM cvcs.corrections
  WHERE repository_id = p_repository_id
    AND corrected_at >= p_since
    AND pattern_key IS NOT NULL
  GROUP BY pattern_key
  HAVING count(*) >= p_min_count
  ORDER BY correction_count DESC
$$;

COMMENT ON FUNCTION cvcs.correction_patterns IS
  'Surfaces recurring correction patterns. High unclosed_count means the cognitive state has not evolved to address a known failure. Feed into the commit workflow.';

-- ============================================================
-- CORRECTION RATE HELPER
--
-- Override rate per decision_type over time.
-- Correction rate climbing = cognitive drift or policy mismatch.
-- Correction rate falling after a commit = the commit worked.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.correction_rate(
  p_repository_id uuid,
  p_since         timestamptz DEFAULT now() - interval '30 days'
)
RETURNS TABLE (
  decision_type     text,
  total_decisions   bigint,
  total_corrections bigint,
  correction_rate   numeric,
  last_corrected_at timestamptz
)
LANGUAGE sql STABLE AS $$
  SELECT
    d.decision_type,
    count(DISTINCT d.id)                                  AS total_decisions,
    count(DISTINCT c.id)                                  AS total_corrections,
    round(
      count(DISTINCT c.id)::numeric / nullif(count(DISTINCT d.id), 0) * 100,
      2
    )                                                     AS correction_rate,
    max(c.corrected_at)                                   AS last_corrected_at
  FROM cvcs.decisions d
  LEFT JOIN cvcs.corrections c ON c.decision_id = d.id
  WHERE d.repository_id = p_repository_id
    AND d.decided_at >= p_since
  GROUP BY d.decision_type
  ORDER BY correction_rate DESC NULLS LAST
$$;

COMMENT ON FUNCTION cvcs.correction_rate IS
  'Override rate per decision type. Rising rate after a commit = regression. Falling rate = the commit addressed the pattern.';
