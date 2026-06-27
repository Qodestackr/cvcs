-- ============================================================
-- BRANCHES
--
-- A branch is a named pointer to the current head commit.
-- main always exists (created by bootstrap_repository).
--
-- forked_from_id + forked_at_hash record exactly where this branch
-- diverged. diff(forked_at_hash, head_commit_id) = the precise
-- delta this branch introduces relative to its origin.
--
-- head_commit_id is null until the first commit lands.
-- Both fork fields must be set together or neither (CHECK-enforced).
-- ============================================================

CREATE TABLE cvcs.branches (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id    uuid        NOT NULL REFERENCES cvcs.repositories(id),
  name             text        NOT NULL,

  head_commit_id   uuid        REFERENCES cvcs.commits(id),

  forked_from_id   uuid        REFERENCES cvcs.branches(id),
  forked_at_hash   text        REFERENCES cvcs.commits(hash),

  description      text,
  created_by       text,

  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  UNIQUE (repository_id, name),

  CHECK (name ~ '^[a-z0-9][a-z0-9\-/]*[a-z0-9]$'),
  CHECK (
    (forked_from_id IS NULL AND forked_at_hash IS NULL)
    OR
    (forked_from_id IS NOT NULL AND forked_at_hash IS NOT NULL)
  )
);

CREATE INDEX branches_repo_idx  ON cvcs.branches (repository_id, name);
CREATE INDEX branches_head_idx  ON cvcs.branches (head_commit_id)  WHERE head_commit_id IS NOT NULL;
CREATE INDEX branches_fork_idx  ON cvcs.branches (forked_from_id)  WHERE forked_from_id IS NOT NULL;

CREATE OR REPLACE FUNCTION cvcs.set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER branches_updated_at
  BEFORE UPDATE ON cvcs.branches
  FOR EACH ROW EXECUTE FUNCTION cvcs.set_updated_at();


-- ============================================================
-- MERGE REQUESTS
--
-- Gated proposal to move organizational knowledge forward.
-- The system diffs and surfaces conflicts. Humans approve.
-- This sequence is not optional.
--
-- status lifecycle: open → approved → merged | rejected | abandoned
--
-- has_conflicts = true requires conflict_summary (CHECK-enforced).
-- A merge request with unresolved conflicts cannot be approved.
--
-- diff_snapshot is frozen at open time — reviewers see what
-- was proposed, not what the source branch looks like later.
--
-- review_note is part of the permanent audit trail.
-- ============================================================

CREATE TABLE cvcs.merge_requests (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id     uuid        NOT NULL REFERENCES cvcs.repositories(id),

  source_branch_id  uuid        NOT NULL REFERENCES cvcs.branches(id),
  target_branch_id  uuid        NOT NULL REFERENCES cvcs.branches(id),

  title             text        NOT NULL,
  description       text,

  status            text        NOT NULL DEFAULT 'open',

  diff_snapshot     jsonb       NOT NULL DEFAULT '{}',
  has_conflicts     boolean     NOT NULL DEFAULT false,
  conflict_summary  text,

  opened_by         text        NOT NULL,
  reviewed_by       text,
  review_note       text,

  merged_commit_id  uuid        REFERENCES cvcs.commits(id),

  opened_at         timestamptz NOT NULL DEFAULT now(),
  decided_at        timestamptz,

  CHECK (length(title) > 0),
  CHECK (length(opened_by) > 0),
  CHECK (source_branch_id <> target_branch_id),
  CHECK (status IN ('open', 'approved', 'merged', 'rejected', 'abandoned')),
  CHECK (
    (status IN ('approved', 'merged', 'rejected')
      AND reviewed_by IS NOT NULL
      AND decided_at  IS NOT NULL)
    OR status IN ('open', 'abandoned')
  ),
  CHECK (
    (status = 'merged' AND merged_commit_id IS NOT NULL)
    OR status <> 'merged'
  ),
  CHECK (
    (has_conflicts = true AND conflict_summary IS NOT NULL)
    OR has_conflicts = false
  )
);

CREATE INDEX mr_repo_status_idx ON cvcs.merge_requests (repository_id, status, opened_at DESC);
CREATE INDEX mr_target_idx      ON cvcs.merge_requests (target_branch_id, status);
CREATE INDEX mr_source_idx      ON cvcs.merge_requests (source_branch_id, status);
CREATE INDEX mr_open_idx        ON cvcs.merge_requests (repository_id, opened_at DESC)
  WHERE status = 'open';


-- ============================================================
-- DELETION PREVENTION
-- Branches and merge requests are mutable by design (pointer
-- advances, status progresses). Deletion is never permitted.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.prevent_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION
    'table % does not permit deletion. Records are permanent.',
    TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER branches_no_delete
  BEFORE DELETE ON cvcs.branches
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_delete();

CREATE TRIGGER mr_no_delete
  BEFORE DELETE ON cvcs.merge_requests
  FOR EACH ROW EXECUTE FUNCTION cvcs.prevent_delete();


-- ============================================================
-- FORK BRANCH
--
-- Creates a new branch from the current head of an existing branch.
-- Raises if the source has no commits — nothing to fork from.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.fork_branch(
  p_repository_id  uuid,
  p_source_name    text,
  p_new_name       text,
  p_created_by     text,
  p_description    text DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_source         cvcs.branches%ROWTYPE;
  v_new_branch_id  uuid;
BEGIN
  SELECT * INTO v_source
  FROM cvcs.branches
  WHERE repository_id = p_repository_id
    AND name          = p_source_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch % not found in repository %', p_source_name, p_repository_id;
  END IF;

  IF v_source.head_commit_id IS NULL THEN
    RAISE EXCEPTION 'cannot fork branch %: no commits yet', p_source_name;
  END IF;

  INSERT INTO cvcs.branches (
    repository_id,
    name,
    head_commit_id,
    forked_from_id,
    forked_at_hash,
    description,
    created_by
  )
  SELECT
    p_repository_id,
    p_new_name,
    v_source.head_commit_id,
    v_source.id,
    c.hash,
    p_description,
    p_created_by
  FROM cvcs.commits c
  WHERE c.id = v_source.head_commit_id
  RETURNING id INTO v_new_branch_id;

  RETURN v_new_branch_id;
END;
$$;


-- ============================================================
-- ADVANCE BRANCH HEAD
--
-- Moves a branch pointer forward to a new commit.
-- Enforces direct ancestry — no force pushes, no history rewriting.
-- Uses FOR UPDATE to prevent concurrent advances from racing.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.advance_branch_head(
  p_branch_id     uuid,
  p_new_commit_id uuid
)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_branch  cvcs.branches%ROWTYPE;
  v_commit  cvcs.commits%ROWTYPE;
BEGIN
  SELECT * INTO v_branch
  FROM cvcs.branches
  WHERE id = p_branch_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch % not found', p_branch_id;
  END IF;

  SELECT * INTO v_commit
  FROM cvcs.commits
  WHERE id = p_new_commit_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'commit % not found', p_new_commit_id;
  END IF;

  IF v_branch.head_commit_id IS NOT NULL THEN
    IF v_commit.parent_hash IS NULL THEN
      RAISE EXCEPTION
        'commit % has no parent but branch % already has a head. history rewriting is not permitted.',
        p_new_commit_id, p_branch_id;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM cvcs.commits
      WHERE id          = p_new_commit_id
        AND parent_hash = (
          SELECT hash FROM cvcs.commits WHERE id = v_branch.head_commit_id
        )
    ) THEN
      RAISE EXCEPTION
        'commit % is not a direct descendant of current head % on branch %. history rewriting is not permitted.',
        p_new_commit_id, v_branch.head_commit_id, p_branch_id;
    END IF;
  END IF;

  UPDATE cvcs.branches
  SET head_commit_id = p_new_commit_id
  WHERE id = p_branch_id;
END;
$$;


-- ============================================================
-- HELPERS
-- ============================================================

-- Commit ancestry chain from head to genesis.
-- Used by merge_base() and branch graph rendering.
CREATE OR REPLACE FUNCTION cvcs.branch_history(p_branch_id uuid)
RETURNS TABLE (
  depth         integer,
  commit_id     uuid,
  commit_hash   text,
  message       text,
  author        text,
  committed_at  timestamptz
) LANGUAGE sql STABLE AS $$
  WITH RECURSIVE history AS (
    SELECT
      0             AS depth,
      c.id,
      c.hash,
      c.message,
      c.author,
      c.committed_at,
      c.parent_hash
    FROM cvcs.branches b
    JOIN cvcs.commits  c ON c.id = b.head_commit_id
    WHERE b.id = p_branch_id
      AND b.head_commit_id IS NOT NULL

    UNION ALL

    SELECT
      h.depth + 1,
      c.id,
      c.hash,
      c.message,
      c.author,
      c.committed_at,
      c.parent_hash
    FROM history       h
    JOIN cvcs.commits  c ON c.hash = h.parent_hash
  )
  SELECT depth, id, hash, message, author, committed_at
  FROM history
  ORDER BY depth
$$;


-- Most recent common ancestor of two branches.
-- Starting point for computing what diverged on each side.
CREATE OR REPLACE FUNCTION cvcs.merge_base(
  p_branch_a_id uuid,
  p_branch_b_id uuid
)
RETURNS TABLE (
  commit_id    uuid,
  commit_hash  text,
  committed_at timestamptz
) LANGUAGE sql STABLE AS $$
  WITH
    ancestry_a AS (SELECT commit_hash FROM cvcs.branch_history(p_branch_a_id)),
    ancestry_b AS (SELECT commit_hash FROM cvcs.branch_history(p_branch_b_id))
  SELECT c.id, c.hash, c.committed_at
  FROM cvcs.commits c
  WHERE c.hash IN (SELECT commit_hash FROM ancestry_a)
    AND c.hash IN (SELECT commit_hash FROM ancestry_b)
  ORDER BY c.committed_at DESC
  LIMIT 1
$$;


-- Open merge requests targeting a branch. The review queue.
CREATE OR REPLACE FUNCTION cvcs.pending_merges(p_target_branch_id uuid)
RETURNS TABLE (
  mr_id             uuid,
  title             text,
  description       text,
  source_branch     text,
  opened_by         text,
  has_conflicts     boolean,
  conflict_summary  text,
  opened_at         timestamptz
) LANGUAGE sql STABLE AS $$
  SELECT
    mr.id,
    mr.title,
    mr.description,
    src.name,
    mr.opened_by,
    mr.has_conflicts,
    mr.conflict_summary,
    mr.opened_at
  FROM cvcs.merge_requests mr
  JOIN cvcs.branches       src ON src.id = mr.source_branch_id
  WHERE mr.target_branch_id = p_target_branch_id
    AND mr.status = 'open'
  ORDER BY mr.opened_at DESC
$$;


-- At-a-glance view of all branches: activity, correction pressure,
-- merge request status. Entry point for the branch graph UI.
--
-- commits_since_fork uses committed_at as a proxy — full ancestry
-- diff happens at merge time, not here.
CREATE OR REPLACE FUNCTION cvcs.branch_summary(p_repository_id uuid)
RETURNS TABLE (
  branch_id          uuid,
  branch_name        text,
  head_commit_hash   text,
  forked_from_name   text,
  commits_since_fork bigint,
  total_decisions    bigint,
  total_corrections  bigint,
  open_mrs           bigint,
  last_commit_at     timestamptz
) LANGUAGE sql STABLE AS $$
  SELECT
    b.id                                                        AS branch_id,
    b.name                                                      AS branch_name,
    hc.hash                                                     AS head_commit_hash,
    fb.name                                                     AS forked_from_name,
    (
      SELECT count(*)
      FROM cvcs.commits cc
      WHERE cc.repository_id = p_repository_id
        AND cc.committed_at > COALESCE(
          (SELECT committed_at FROM cvcs.commits WHERE hash = b.forked_at_hash),
          '-infinity'::timestamptz
        )
        AND cc.committed_at <= COALESCE(hc.committed_at, now())
        AND EXISTS (
          SELECT 1 FROM cvcs.branch_history(b.id) bh
          WHERE bh.commit_hash = cc.hash
        )
    )                                                           AS commits_since_fork,
    count(DISTINCT d.id)                                        AS total_decisions,
    count(DISTINCT co.id)                                       AS total_corrections,
    count(DISTINCT mr.id) FILTER (WHERE mr.status = 'open')    AS open_mrs,
    hc.committed_at                                             AS last_commit_at
  FROM cvcs.branches b
  LEFT JOIN cvcs.commits        hc ON hc.id = b.head_commit_id
  LEFT JOIN cvcs.branches       fb ON fb.id = b.forked_from_id
  LEFT JOIN cvcs.decisions       d ON d.repository_id = p_repository_id
                                   AND d.branch_id = b.id
  LEFT JOIN cvcs.corrections    co ON co.decision_id = d.id
  LEFT JOIN cvcs.merge_requests mr ON mr.repository_id = p_repository_id
                                   AND (mr.source_branch_id = b.id
                                     OR mr.target_branch_id = b.id)
  WHERE b.repository_id = p_repository_id
  GROUP BY
    b.id, b.name, b.forked_at_hash,
    hc.hash, hc.committed_at,
    fb.name
  ORDER BY hc.committed_at DESC NULLS LAST
$$;


-- ============================================================
-- BOOTSTRAP
-- Creates a repository and its initial main branch atomically.
-- Call once per agent system at setup time.
-- ============================================================

CREATE OR REPLACE FUNCTION cvcs.bootstrap_repository(
  p_slug        text,
  p_name        text,
  p_description text DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_repo_id uuid;
BEGIN
  INSERT INTO cvcs.repositories (slug, name, description)
  VALUES (p_slug, p_name, p_description)
  RETURNING id INTO v_repo_id;

  INSERT INTO cvcs.branches (repository_id, name)
  VALUES (v_repo_id, 'main');

  RETURN v_repo_id;
END;
$$;