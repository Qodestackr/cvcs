-- ============================================================
-- The git object model for cognition.
-- Three tables. One invariant: nothing is ever overwritten.
--
--   blobs   = the atomic content unit (what changed)
--   commits = the immutable snapshot (when and why)
--   trees   = the mapping (which blobs at which paths)
--
-- A commit without blobs is just a message.
-- A blob without a commit is unreachable.
-- The tree is what connects them.
-- ============================================================

-- ============================================================
-- BLOBS
--
-- Content-addressed storage. The fundamental unit.
-- A blob is any piece of cognitive content:
--   policy, prompt, knowledge chunk, workflow, tool spec.
--
-- The hash is computed as:
--   sha256(blob_type || ':' || content::text)
--
-- Same content always produces the same hash.
-- Two commits referencing the same blob pay zero storage cost.
-- This is the deduplication moat.
-- ============================================================

CREATE TABLE cvcs.blobs (
  hash        text        PRIMARY KEY,
  blob_type   text        NOT NULL,
  content     jsonb       NOT NULL,
  byte_size   integer     NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),

  CHECK (blob_type IN ('policy', 'prompt', 'knowledge', 'workflow', 'tool', 'context')),
  CHECK (byte_size > 0)
);

CREATE INDEX blobs_type_idx ON cvcs.blobs (blob_type, created_at DESC);

COMMENT ON TABLE cvcs.blobs IS
  'Content-addressed storage. Same content = same hash. No duplicates. The atomic unit of cognitive state.';

COMMENT ON COLUMN cvcs.blobs.hash IS
  'sha256(blob_type || '':'' || content::text). Computed by the application before insert. Never trust a caller-supplied hash without verifying.';

COMMENT ON COLUMN cvcs.blobs.content IS
  'The actual cognitive artifact. For prompts: the full template. For policies: structured rules. For knowledge: the chunk with metadata. Schema is blob_type-specific and owned by the runtime.';

-- ============================================================
-- COMMITS
--
-- The irreversible unit of change. A commit is a snapshot
-- of the full cognitive context at a point in time.
--
-- parent_hash creates the history chain. The root commit
-- (first in a repo) has parent_hash = null.
--
-- tree_hash is the sha256 of all (path, blob_hash) pairs
-- sorted deterministically. If the tree did not change,
-- the tree_hash does not change. This makes commit comparison
-- O(1) before you even look at individual blobs.
--
-- The full commit hash is computed as:
--   sha256(parent_hash || tree_hash || author || message)
-- This means the hash encodes history. You cannot rewrite
-- the past without invalidating every descendant hash.
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
  CHECK (length(author) > 0),
  CHECK (length(hash) = 64),
  CHECK (length(tree_hash) = 64)
);

CREATE INDEX commits_repository_time_idx ON cvcs.commits (repository_id, committed_at DESC);
CREATE INDEX commits_parent_idx          ON cvcs.commits (parent_hash) WHERE parent_hash IS NOT NULL;
CREATE INDEX commits_tree_idx            ON cvcs.commits (tree_hash);

COMMENT ON TABLE cvcs.commits IS
  'Immutable snapshots of full cognitive context. Parent chain is the history. Nothing is overwritten.';

COMMENT ON COLUMN cvcs.commits.hash IS
  'sha256(parent_hash || tree_hash || author || message). Encodes history: rewriting the past invalidates all descendants.';

COMMENT ON COLUMN cvcs.commits.tree_hash IS
  'sha256 of all sorted (path, blob_hash) pairs in this commit. Equal tree_hash = identical cognitive state. O(1) equality check.';

COMMENT ON COLUMN cvcs.commits.parent_hash IS
  'null only for the root commit of a repository. Every other commit knows its parent.';

COMMENT ON COLUMN cvcs.commits.metadata IS
  'Arbitrary runtime metadata. Use for: model_id used at commit time, environment tag, triggering event id, external reference.';

-- ============================================================
-- TREES (commit_blobs)
--
-- The mapping between a commit and its blobs.
-- path is a namespaced key in the cognitive filesystem:
--
--   policies/credit_approval
--   prompts/order_parsing/system
--   prompts/order_parsing/user
--   knowledge/sku_catalog
--   workflows/fulfillment
--   tools/inventory_check
--
-- At any commit, the full cognitive context is the set of
-- all (path, blob_hash) pairs. This is what gets hydrated
-- before calling the model. This is what gets diffed.
-- ============================================================

CREATE TABLE cvcs.trees (
  commit_id   uuid    NOT NULL REFERENCES cvcs.commits(id),
  path        text    NOT NULL,
  blob_hash   text    NOT NULL REFERENCES cvcs.blobs(hash),
  PRIMARY KEY (commit_id, path),

  CHECK (path ~ '^[a-z0-9_][a-z0-9_/\-\.]*[a-z0-9_]$')
);

CREATE INDEX trees_blob_idx   ON cvcs.trees (blob_hash);
CREATE INDEX trees_path_idx   ON cvcs.trees (path, commit_id);

COMMENT ON TABLE cvcs.trees IS
  'The cognitive filesystem at a commit. Every (commit_id, path) maps to exactly one blob. This is what gets hydrated before model execution.';

COMMENT ON COLUMN cvcs.trees.path IS
  'Namespaced key in the cognitive filesystem. Convention: type/name[/variant]. e.g. prompts/credit_check/system, policies/approval_threshold.';

-- ============================================================
-- APPEND-ONLY ENFORCEMENT
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.prevent_update_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION
    'table % is append-only: updates and deletes are not permitted. create a new commit instead.',
    TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END;
$$;

CREATE TRIGGER blobs_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.blobs
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

CREATE TRIGGER commits_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.commits
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

CREATE TRIGGER trees_no_mutate
  BEFORE UPDATE OR DELETE ON cvcs.trees
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_update_delete();

-- ============================================================
-- DIFF HELPER
--
-- Given two commit ids, returns all paths that changed:
-- added, removed, or modified (blob_hash changed).
-- The runtime uses this to generate plain-language diffs.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.diff_commits(
  p_from_commit_id uuid,
  p_to_commit_id   uuid
)
RETURNS TABLE (
  path        text,
  change_type text,   -- 'added' | 'removed' | 'modified'
  from_hash   text,
  to_hash     text
)
LANGUAGE sql STABLE AS $$
  WITH
    from_tree AS (SELECT path, blob_hash FROM cvcs.trees WHERE commit_id = p_from_commit_id),
    to_tree   AS (SELECT path, blob_hash FROM cvcs.trees WHERE commit_id = p_to_commit_id)
  SELECT
    COALESCE(f.path, t.path)                       AS path,
    CASE
      WHEN f.path IS NULL                          THEN 'added'
      WHEN t.path IS NULL                          THEN 'removed'
      ELSE                                              'modified'
    END                                            AS change_type,
    f.blob_hash                                    AS from_hash,
    t.blob_hash                                    AS to_hash
  FROM from_tree f
  FULL OUTER JOIN to_tree t USING (path)
  WHERE f.blob_hash IS DISTINCT FROM t.blob_hash
  ORDER BY path
$$;

COMMENT ON FUNCTION cvcs.diff_commits IS
  'Returns all paths that changed between two commits. Feed the results into the runtime diff renderer to produce plain-language output.';

-- ============================================================
-- HYDRATE HELPER
--
-- Given a commit id, returns the full cognitive context:
-- every (path, blob_type, content) pair.
-- This is the single call the runtime makes before execution.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.hydrate_commit(p_commit_id uuid)
RETURNS TABLE (
  path        text,
  blob_hash   text,
  blob_type   text,
  content     jsonb
)
LANGUAGE sql STABLE AS $$
  SELECT
    t.path,
    t.blob_hash,
    b.blob_type,
    b.content
  FROM cvcs.trees t
  JOIN cvcs.blobs b ON b.hash = t.blob_hash
  WHERE t.commit_id = p_commit_id
  ORDER BY t.path
$$;

COMMENT ON FUNCTION cvcs.hydrate_commit IS
  'Returns the full cognitive context for a commit. The runtime calls this once before every model execution.';