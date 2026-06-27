-- ============================================================
-- DECISIONS
--
-- One row per model execution, tied to the exact commit active at runtime.
--
-- commit_id + prompt_path fully reconstruct what the model knew —
-- this is what makes deterministic replay possible years later.
--
-- input_hash = sha256(raw_input). Used to find decisions that received
-- identical inputs — prerequisite for replay comparison.
--
-- decision_type is domain-defined ("order_parse", "credit_approval", etc.)
-- and is not enforced by the schema.
-- ============================================================

CREATE TABLE cvcs.decisions (
  id              uuid             PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id   uuid             NOT NULL REFERENCES cvcs.repositories(id),
  commit_id       uuid             NOT NULL REFERENCES cvcs.commits(id),

  decision_type   text             NOT NULL,
  input_hash      text             NOT NULL,
  raw_input       text             NOT NULL,
  raw_output      text             NOT NULL,

  model_id        text             NOT NULL,
  model_version   text,

  prompt_path     text             NOT NULL,

  confidence      double precision,
  latency_ms      integer,
  token_count     integer,

  metadata        jsonb            NOT NULL DEFAULT '{}',
  decided_at      timestamptz      NOT NULL DEFAULT now(),

  CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1),
  CHECK (latency_ms IS NULL OR latency_ms >= 0),
  CHECK (token_count IS NULL OR token_count > 0),
  CHECK (length(decision_type) > 0),
  CHECK (length(model_id) > 0),
  CHECK (length(prompt_path) > 0)
);

CREATE INDEX decisions_commit_idx     ON cvcs.decisions (commit_id, decided_at DESC);
CREATE INDEX decisions_repo_type_idx  ON cvcs.decisions (repository_id, decision_type, decided_at DESC);
CREATE INDEX decisions_input_hash_idx ON cvcs.decisions (input_hash);
CREATE INDEX decisions_model_idx      ON cvcs.decisions (model_id, decided_at DESC);
CREATE INDEX decisions_decided_at_idx ON cvcs.decisions (decided_at DESC);


-- ============================================================
-- REPLAYS
--
-- Re-executes a historical decision against a different commit,
-- a different model, or both. Each run is its own permanent row.
--
-- Use cases: drift measurement, model upgrade validation, policy audits.
--
-- output_matches = false requires a divergence_summary (CHECK-enforced).
-- The runtime computes output_matches — exact string equality for MVP,
-- semantic equivalence via embedding later.
--
-- diff_snapshot is frozen at replay time, not recomputed on re-run.
-- ============================================================

CREATE TABLE cvcs.replays (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id         uuid        NOT NULL REFERENCES cvcs.repositories(id),
  original_decision_id  uuid        NOT NULL REFERENCES cvcs.decisions(id),

  replay_commit_id      uuid        NOT NULL REFERENCES cvcs.commits(id),
  replay_model_id       text        NOT NULL,

  raw_output            text        NOT NULL,
  output_matches        boolean     NOT NULL,
  divergence_summary    text,

  latency_ms            integer,
  token_count           integer,
  metadata              jsonb       NOT NULL DEFAULT '{}',
  replayed_at           timestamptz NOT NULL DEFAULT now(),

  CHECK (length(replay_model_id) > 0),
  CHECK (latency_ms IS NULL OR latency_ms >= 0),
  CHECK (token_count IS NULL OR token_count > 0),
  CHECK (
    (output_matches = false AND divergence_summary IS NOT NULL)
    OR output_matches = true
  )
);

CREATE INDEX replays_original_idx   ON cvcs.replays (original_decision_id, replayed_at DESC);
CREATE INDEX replays_commit_idx     ON cvcs.replays (replay_commit_id, replayed_at DESC);
CREATE INDEX replays_mismatch_idx   ON cvcs.replays (repository_id, output_matches, replayed_at DESC)
  WHERE output_matches = false;


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
-- HELPERS
-- ============================================================

-- Everything needed to replay a decision: commit state, prompt content,
-- original input/output. Called by the runtime before constructing a replay.
CREATE OR REPLACE FUNCTION cvcs.replay_context(p_decision_id uuid)
RETURNS TABLE (
  decision_id     uuid,
  commit_hash     text,
  model_id        text,
  prompt_path     text,
  prompt_content  jsonb,
  raw_input       text,
  raw_output      text,
  decided_at      timestamptz
) LANGUAGE sql STABLE AS $$
  SELECT
    d.id,
    c.hash,
    d.model_id,
    d.prompt_path,
    b.content,
    d.raw_input,
    d.raw_output,
    d.decided_at
  FROM cvcs.decisions d
  JOIN cvcs.commits      c  ON c.id = d.commit_id
  JOIN cvcs.commit_blobs cb ON cb.commit_id = d.commit_id
                            AND cb.path = d.prompt_path
  JOIN cvcs.blobs        b  ON b.hash = cb.blob_hash
  WHERE d.id = p_decision_id
$$;


-- Drift summary across all replays of a decision:
-- total runs, match count, drift rate, commits tested.
CREATE OR REPLACE FUNCTION cvcs.decision_drift(p_decision_id uuid)
RETURNS TABLE (
  total_replays     bigint,
  matching_replays  bigint,
  drift_rate        numeric,
  commits_tested    text[]
) LANGUAGE sql STABLE AS $$
  SELECT
    COUNT(*)                                        AS total_replays,
    COUNT(*) FILTER (WHERE output_matches = true)   AS matching_replays,
    ROUND(
      1.0 - COUNT(*) FILTER (WHERE output_matches = true)::numeric
            / NULLIF(COUNT(*), 0),
      4
    )                                               AS drift_rate,
    ARRAY_AGG(DISTINCT c.hash ORDER BY c.hash)      AS commits_tested
  FROM cvcs.replays  r
  JOIN cvcs.commits  c ON c.id = r.replay_commit_id
  WHERE r.original_decision_id = p_decision_id
$$;