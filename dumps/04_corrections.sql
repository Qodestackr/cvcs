-- ============================================================
-- CORRECTIONS
--
-- One row per human override of a model decision.
--
-- correction_scope narrows what was wrong:
--   'output'   — full output was wrong
--   'partial'  — a field or section was wrong
--   'routing'  — right answer, wrong destination
--   'policy'   — the rule itself needs updating
--
-- reason is optional. Silent corrections (no reason) are often
-- high signal — the human considered the context obvious.
--
-- produced_commit_id closes the loop: correction → new commit
-- → future decisions informed. Null means not yet acted on.
-- ============================================================

CREATE TABLE cvcs.corrections (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_id         uuid        NOT NULL REFERENCES cvcs.decisions(id),
  repository_id       uuid        NOT NULL REFERENCES cvcs.repositories(id),

  corrected_by        text        NOT NULL,
  correction_scope    text        NOT NULL DEFAULT 'output',

  original_output     text        NOT NULL,
  corrected_output    text        NOT NULL,

  reason              text,
  internal_note       text,

  produced_commit_id  uuid        REFERENCES cvcs.commits(id),

  corrected_at        timestamptz NOT NULL DEFAULT now(),

  CHECK (correction_scope IN ('output', 'partial', 'routing', 'policy')),
  CHECK (length(corrected_by) > 0),
  CHECK (original_output <> corrected_output)
);

CREATE INDEX corrections_decision_idx     ON cvcs.corrections (decision_id);
CREATE INDEX corrections_repo_idx         ON cvcs.corrections (repository_id, corrected_at DESC);
CREATE INDEX corrections_actor_idx        ON cvcs.corrections (repository_id, corrected_by, corrected_at DESC);
CREATE INDEX corrections_scope_idx        ON cvcs.corrections (repository_id, correction_scope, corrected_at DESC);
CREATE INDEX corrections_open_loop_idx    ON cvcs.corrections (repository_id, corrected_at DESC)
  WHERE produced_commit_id IS NULL;


-- ============================================================
-- CORRECTION PATTERNS
--
-- Detected recurrences written by the pattern detection job,
-- not by humans. Reviewed and ratified by humans.
--
-- status lifecycle: detected → reviewed → ratified | dismissed
--
-- example_decision_ids: a sample of contributing decisions,
-- so reviewers can inspect without running a query.
-- ============================================================

CREATE TABLE cvcs.correction_patterns (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id         uuid        NOT NULL REFERENCES cvcs.repositories(id),

  decision_type         text        NOT NULL,
  pattern_summary       text        NOT NULL,
  inferred_rule         text,

  correction_count      integer     NOT NULL,
  first_seen_at         timestamptz NOT NULL,
  last_seen_at          timestamptz NOT NULL,

  status                text        NOT NULL DEFAULT 'detected',
  reviewed_by           text,
  reviewed_at           timestamptz,

  example_decision_ids  uuid[]      NOT NULL DEFAULT '{}',

  detected_at           timestamptz NOT NULL DEFAULT now(),

  CHECK (status IN ('detected', 'reviewed', 'ratified', 'dismissed')),
  CHECK (correction_count > 0),
  CHECK (
    (status IN ('reviewed', 'ratified', 'dismissed') AND reviewed_by IS NOT NULL)
    OR status = 'detected'
  )
);

CREATE INDEX patterns_repo_status_idx ON cvcs.correction_patterns (repository_id, status, last_seen_at DESC);
CREATE INDEX patterns_type_idx        ON cvcs.correction_patterns (repository_id, decision_type, last_seen_at DESC);
CREATE INDEX patterns_active_idx      ON cvcs.correction_patterns (repository_id, last_seen_at DESC)
  WHERE status IN ('detected', 'reviewed');


-- ============================================================
-- RATIFIED RULES
--
-- A correction pattern approved as an explicit organizational rule.
-- On ratification, a blob is written and committed into the tree —
-- the model sees it on future runs.
--
-- valid_from / valid_until are the temporal validity window.
-- valid_until = NULL means currently active.
-- superseded_by links to the rule that replaced this one,
-- building a temporal chain of how rules evolved.
-- ============================================================

CREATE TABLE cvcs.ratified_rules (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id       uuid        NOT NULL REFERENCES cvcs.repositories(id),
  pattern_id          uuid        NOT NULL REFERENCES cvcs.correction_patterns(id),

  rule_text           text        NOT NULL,
  decision_type       text        NOT NULL,

  blob_hash           text        REFERENCES cvcs.blobs(hash),
  produced_commit_id  uuid        REFERENCES cvcs.commits(id),

  ratified_by         text        NOT NULL,
  ratified_at         timestamptz NOT NULL DEFAULT now(),

  valid_from          timestamptz NOT NULL DEFAULT now(),
  valid_until         timestamptz,
  superseded_by       uuid        REFERENCES cvcs.ratified_rules(id),

  CHECK (length(rule_text) > 0),
  CHECK (length(ratified_by) > 0),
  CHECK (valid_until IS NULL OR valid_until > valid_from)
);

CREATE INDEX ratified_rules_repo_idx    ON cvcs.ratified_rules (repository_id, valid_from DESC);
CREATE INDEX ratified_rules_type_idx    ON cvcs.ratified_rules (repository_id, decision_type, valid_from DESC);
CREATE INDEX ratified_rules_active_idx  ON cvcs.ratified_rules (repository_id, valid_from DESC)
  WHERE valid_until IS NULL;


-- ============================================================
-- APPEND-ONLY ENFORCEMENT
--
-- Corrections and patterns: fully immutable.
-- Ratified rules: one permitted update — setting valid_until
-- to supersede a rule. All other columns are frozen.
-- ============================================================

CREATE TRIGGER corrections_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.corrections
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

CREATE TRIGGER patterns_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.correction_patterns
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

CREATE OR REPLACE FUNCTION cvcs.ratified_rules_allow_supersede()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.valid_until IS NOT NULL THEN
    RAISE EXCEPTION 'ratified_rules: rule % is already superseded and cannot be modified', OLD.id;
  END IF;
  IF NEW.valid_until IS NULL THEN
    RAISE EXCEPTION 'ratified_rules: the only permitted update is setting valid_until to supersede a rule';
  END IF;
  IF (NEW.rule_text, NEW.decision_type, NEW.ratified_by, NEW.ratified_at, NEW.valid_from, NEW.pattern_id, NEW.repository_id)
     IS DISTINCT FROM
     (OLD.rule_text, OLD.decision_type, OLD.ratified_by, OLD.ratified_at, OLD.valid_from, OLD.pattern_id, OLD.repository_id)
  THEN
    RAISE EXCEPTION 'ratified_rules: only valid_until and superseded_by may change when superseding a rule';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER ratified_rules_supersede_only
  BEFORE UPDATE ON cvcs.ratified_rules
  FOR EACH ROW EXECUTE FUNCTION cvcs.ratified_rules_allow_supersede();

CREATE TRIGGER ratified_rules_no_delete
  BEFORE DELETE ON cvcs.ratified_rules
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();


-- ============================================================
-- HELPERS
-- ============================================================

-- All corrections for a decision, with commit context.
-- Used by the pattern detection job and review UI.
CREATE OR REPLACE FUNCTION cvcs.corrections_for_decision(p_decision_id uuid)
RETURNS TABLE (
  correction_id     uuid,
  corrected_by      text,
  correction_scope  text,
  original_output   text,
  corrected_output  text,
  reason            text,
  corrected_at      timestamptz,
  commit_hash       text,
  decision_type     text
) LANGUAGE sql STABLE AS $$
  SELECT
    c.id,
    c.corrected_by,
    c.correction_scope,
    c.original_output,
    c.corrected_output,
    c.reason,
    c.corrected_at,
    cm.hash,
    d.decision_type
  FROM cvcs.corrections  c
  JOIN cvcs.decisions    d  ON d.id = c.decision_id
  JOIN cvcs.commits      cm ON cm.id = d.commit_id
  WHERE c.decision_id = p_decision_id
  ORDER BY c.corrected_at DESC
$$;


-- Patterns awaiting human review or ratification.
-- Primary input for the learning loop review workflow.
CREATE OR REPLACE FUNCTION cvcs.open_patterns(p_repository_id uuid)
RETURNS TABLE (
  pattern_id        uuid,
  decision_type     text,
  pattern_summary   text,
  inferred_rule     text,
  correction_count  integer,
  first_seen_at     timestamptz,
  last_seen_at      timestamptz
) LANGUAGE sql STABLE AS $$
  SELECT
    id,
    decision_type,
    pattern_summary,
    inferred_rule,
    correction_count,
    first_seen_at,
    last_seen_at
  FROM cvcs.correction_patterns
  WHERE repository_id = p_repository_id
    AND status IN ('detected', 'reviewed')
  ORDER BY last_seen_at DESC
$$;


-- Currently active ratified rules for a repository and decision type.
-- Called at runtime to include ratified organizational learning in model context.
CREATE OR REPLACE FUNCTION cvcs.active_rules(
  p_repository_id uuid,
  p_decision_type text DEFAULT NULL
)
RETURNS TABLE (
  rule_id       uuid,
  rule_text     text,
  decision_type text,
  blob_hash     text,
  valid_from    timestamptz
) LANGUAGE sql STABLE AS $$
  SELECT
    id,
    rule_text,
    decision_type,
    blob_hash,
    valid_from
  FROM cvcs.ratified_rules
  WHERE repository_id = p_repository_id
    AND valid_until IS NULL
    AND (p_decision_type IS NULL OR decision_type = p_decision_type)
  ORDER BY valid_from DESC
$$;