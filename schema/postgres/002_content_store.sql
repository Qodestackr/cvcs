-- ============================================================
-- BLOBS
--
-- Atomic unit of cognitive content. Types:
--   policy, prompt, knowledge, workflow, tool, context
--
-- Hash = sha256(blob_type || ':' || content::text).
-- Same content = same hash. Deduplication is automatic.
--
-- content is jsonb — structured data lives natively.
-- For plain text prompts, wrap as: {"text": "..."}
-- ============================================================

CREATE TABLE cvcs.blobs (
  hash        text        PRIMARY KEY,
  blob_type   text        NOT NULL,
  content     jsonb       NOT NULL,
  byte_size   integer     NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),

  CHECK (blob_type IN ('policy', 'prompt', 'knowledge', 'workflow', 'tool', 'context')),
  CHECK (byte_size > 0),
  CHECK (hash = encode(digest(blob_type || ':' || content::text, 'sha256'), 'hex'))
);

CREATE INDEX blobs_type_idx ON cvcs.blobs (blob_type, created_at DESC);


-- ============================================================
-- COMMITS
--
-- Immutable snapshot of full cognitive context at a point in time.
--
-- hash = sha256(parent_hash || tree_hash || message || author)
-- Tamper-evident: changing any commit invalidates all descendants.
--
-- tree_hash is a content address, not a FK — resolved via commit_blobs.
-- parent_hash is null only for the genesis commit.
-- committed_at is wall clock — use the parent chain for causal ordering.
-- ============================================================

CREATE TABLE cvcs.commits (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id uuid        NOT NULL REFERENCES cvcs.repositories(id),
  hash          text        NOT NULL UNIQUE,
  parent_hash   text        REFERENCES cvcs.commits(hash),
  tree_hash     text        NOT NULL,
  message       text        NOT NULL,
  author        text        NOT NULL,
  metadata      jsonb       NOT NULL DEFAULT '{}',
  committed_at  timestamptz NOT NULL DEFAULT now(),

  CHECK (length(message) > 0),
  CHECK (length(author) > 0)
);

CREATE INDEX commits_repository_idx ON cvcs.commits (repository_id, committed_at DESC);
CREATE INDEX commits_parent_idx     ON cvcs.commits (parent_hash) WHERE parent_hash IS NOT NULL;
CREATE INDEX commits_hash_prefix    ON cvcs.commits USING gin (hash gin_trgm_ops);


-- ============================================================
-- COMMIT BLOBS (the tree)
--
-- Maps each commit to the exact blobs active at that moment.
--
-- path is a namespaced key: "prompts/system", "policies/credit_approval", etc.
-- Same blob_hash can appear at the same path across many commits —
-- unchanged blobs are shared, not duplicated.
-- ============================================================

CREATE TABLE cvcs.commit_blobs (
  commit_id   uuid    NOT NULL REFERENCES cvcs.commits(id),
  path        text    NOT NULL,
  blob_hash   text    NOT NULL REFERENCES cvcs.blobs(hash),

  PRIMARY KEY (commit_id, path),
  CHECK (path ~ '^[a-z0-9_][a-z0-9_/\-\.]*$')
);

CREATE INDEX commit_blobs_hash_idx   ON cvcs.commit_blobs (blob_hash);
CREATE INDEX commit_blobs_path_idx   ON cvcs.commit_blobs (path, commit_id);


-- ============================================================
-- APPEND-ONLY ENFORCEMENT
-- No UPDATE. No DELETE. To change something, make a new commit.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.prevent_update_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION
    'table % is append-only: UPDATE and DELETE are not permitted. Make a new commit instead.',
    TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER blobs_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.blobs
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

CREATE TRIGGER commits_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.commits
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

CREATE TRIGGER commit_blobs_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.commit_blobs
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();


-- ============================================================
-- HELPERS
-- ============================================================

-- Full blob tree for a commit. Called by the runtime engine
-- to hydrate context before every model execution.
CREATE OR REPLACE FUNCTION cvcs.hydrate_commit(p_commit_id uuid)
RETURNS TABLE (
  path          text,
  blob_type     text,
  blob_hash     text,
  content       jsonb
) LANGUAGE sql STABLE AS $$
  SELECT
    cb.path,
    b.blob_type,
    b.hash,
    b.content
  FROM cvcs.commit_blobs cb
  JOIN cvcs.blobs b ON b.hash = cb.blob_hash
  WHERE cb.commit_id = p_commit_id
  ORDER BY cb.path
$$;


-- Path-level diff between two commits: added / removed / modified / unchanged.
CREATE OR REPLACE FUNCTION cvcs.diff_commits(
  p_base_commit_id    uuid,
  p_compare_commit_id uuid
)
RETURNS TABLE (
  path          text,
  change_type   text,   -- 'added' | 'removed' | 'modified' | 'unchanged'
  base_hash     text,
  compare_hash  text
) LANGUAGE sql STABLE AS $$
  SELECT
    COALESCE(base.path, cmp.path)                          AS path,
    CASE
      WHEN base.path IS NULL                               THEN 'added'
      WHEN cmp.path  IS NULL                               THEN 'removed'
      WHEN base.blob_hash <> cmp.blob_hash                THEN 'modified'
      ELSE                                                      'unchanged'
    END                                                    AS change_type,
    base.blob_hash                                         AS base_hash,
    cmp.blob_hash                                          AS compare_hash
  FROM
    cvcs.commit_blobs base
    FULL OUTER JOIN cvcs.commit_blobs cmp
      ON cmp.commit_id = p_compare_commit_id
     AND cmp.path      = base.path
  WHERE base.commit_id = p_base_commit_id
     OR cmp.commit_id  = p_compare_commit_id
  ORDER BY path
$$;