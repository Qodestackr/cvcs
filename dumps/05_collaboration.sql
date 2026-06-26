-- ============================================================
-- The collaboration layer.
-- Two tables:
--
--   branches       = named pointers into the commit chain
--   merge_requests = gated proposals to evolve shared knowledge
--
-- Branches are the only mutable thing in CVCS.
-- Everything else is append-only. A branch is just a pointer
-- that moves forward. head_commit_id advances. Nothing else
-- about the past changes.
--
-- Merge requests enforce the rule that organizational
-- knowledge evolves only through explicit human approval.
-- The system can propose. Humans decide.
-- ============================================================

-- ============================================================
-- BRANCHES
--
-- A branch is a named pointer to the current head commit
-- of a cognitive timeline.
--
-- main always exists (created by bootstrap_repository).
-- All other branches are created by forking from an existing
-- branch at a specific commit.
--
-- forked_from_id + forked_at_hash record exactly where the
-- branch diverged from its parent. This is what makes branch
-- comparison deterministic: diff(forked_at_hash, head_commit)
-- shows exactly what this branch has added since the fork.
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

CREATE INDEX branches_repository_idx  ON cvcs.branches (repository_id, name);
CREATE INDEX branches_head_idx        ON cvcs.branches (head_commit_id) WHERE head_commit_id IS NOT NULL;
CREATE INDEX branches_fork_idx        ON cvcs.branches (forked_from_id) WHERE forked_from_id IS NOT NULL;

COMMENT ON TABLE cvcs.branches IS
  'Named pointers into the commit chain. The only mutable table in CVCS. head_commit_id is the only thing that moves.';

COMMENT ON COLUMN cvcs.branches.head_commit_id IS
  'The current tip of this branch. Null until the first commit lands on this branch. Advances on every new commit.';

COMMENT ON COLUMN cvcs.branches.forked_from_id IS
  'The parent branch this was forked from. Null only for main. Together with forked_at_hash, defines the exact divergence point.';

COMMENT ON COLUMN cvcs.branches.forked_at_hash IS
  'The commit hash at the moment of fork. diff(forked_at_hash, head_commit_id) is the exact delta this branch introduces.';

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
-- A proposal to move organizational knowledge forward by
-- merging one branch into another.
--
-- The system can diff and surface conflicts automatically.
-- The human must approve before the merge commit is created.
-- This is not a suggestion. It is an architectural constraint.
--
-- conflict_summary is plain language, not a raw diff.
-- The runtime generates it. The human reads it.
--
-- diff_snapshot is the structured diff at the time the
-- merge request was opened. It is frozen so that the review
-- reflects what was proposed, not what the source branch
-- looks like if commits land after the MR opens.
--
-- merged_commit_id is set only after approval + merge.
-- It points to the new commit on target_branch that
-- incorporates the source changes.
-- ============================================================

CREATE TABLE cvcs.merge_requests (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  repository_id     uuid        NOT NULL REFERENCES cvcs.repositories(id),
  source_branch_id  uuid        NOT NULL REFERENCES cvcs.branches(id),
  target_branch_id  uuid        NOT NULL REFERENCES cvcs.branches(id),

  title             text        NOT NULL,
  description       text,

  status            text        NOT NULL DEFAULT 'open',

  -- structured diff at the time of opening (frozen)
  diff_snapshot     jsonb       NOT NULL DEFAULT '{}',

  -- plain language conflict description if any
  conflict_summary  text,
  has_conflicts     boolean     NOT NULL DEFAULT false,

  -- audit
  opened_by         text        NOT NULL,
  reviewed_by       text,
  review_note       text,

  -- result
  merged_commit_id  uuid        REFERENCES cvcs.commits(id),

  opened_at         timestamptz NOT NULL DEFAULT now(),
  decided_at        timestamptz,

  CHECK (length(title) > 0),
  CHECK (length(opened_by) > 0),
  CHECK (source_branch_id <> target_branch_id),
  CHECK (status IN ('open', 'approved', 'merged', 'rejected', 'abandoned')),
  CHECK (
    (status IN ('approved', 'merged', 'rejected') AND reviewed_by IS NOT NULL AND decided_at IS NOT NULL)
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

CREATE INDEX merge_requests_repository_idx  ON cvcs.merge_requests (repository_id, status, opened_at DESC);
CREATE INDEX merge_requests_source_idx      ON cvcs.merge_requests (source_branch_id, status);
CREATE INDEX merge_requests_target_idx      ON cvcs.merge_requests (target_branch_id, status);
CREATE INDEX merge_requests_open_idx        ON cvcs.merge_requests (repository_id, opened_at DESC) WHERE status = 'open';

COMMENT ON TABLE cvcs.merge_requests IS
  'Gated proposals to evolve shared cognitive state. The system diffs and detects conflicts. The human approves. This sequence is not optional.';

COMMENT ON COLUMN cvcs.merge_requests.diff_snapshot IS
  'Frozen structured diff at the time of opening. Preserved so reviewers see what was proposed, not what the source branch looks like later.';

COMMENT ON COLUMN cvcs.merge_requests.conflict_summary IS
  'Plain language description of conflicts. Generated by the runtime diff renderer. Written for humans, not machines.';

COMMENT ON COLUMN cvcs.merge_requests.merged_commit_id IS
  'The new commit on target_branch that incorporates the source changes. Set only after approval and merge execution.';

-- ============================================================
-- FORK HELPER
--
-- Creates a new branch forked from an existing branch at its
-- current head. Atomic. Returns the new branch id.
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
    AND name = p_source_name;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch % not found in repository %', p_source_name, p_repository_id;
  END IF;

  IF v_source.head_commit_id IS NULL THEN
    RAISE EXCEPTION 'cannot fork branch % with no commits yet', p_source_name;
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

COMMENT ON FUNCTION cvcs.fork_branch IS
  'Creates a new branch forked from the current head of an existing branch. Atomic. The fork point is recorded precisely so branch diffs are deterministic.';

-- ============================================================
-- ADVANCE HEAD HELPER
--
-- Moves a branch pointer forward to a new commit.
-- Called by the runtime after every successful commit.
-- Validates that the new commit is a descendant of the
-- current head (no force pushes, no history rewriting).
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

  -- if branch has a head, the new commit must descend from it
  IF v_branch.head_commit_id IS NOT NULL THEN
    IF v_commit.parent_hash IS NULL THEN
      RAISE EXCEPTION
        'commit % has no parent but branch % already has a head commit. history rewriting is not permitted.',
        p_new_commit_id, p_branch_id;
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM cvcs.commits
      WHERE id = p_new_commit_id
        AND parent_hash = (SELECT hash FROM cvcs.commits WHERE id = v_branch.head_commit_id)
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

COMMENT ON FUNCTION cvcs.advance_branch_head IS
  'Moves a branch pointer forward to a new commit. Enforces ancestry: the new commit must be a direct descendant of the current head. No force pushes.';

-- ============================================================
-- BRANCH SUMMARY HELPER
--
-- At-a-glance view of all branches in a repository.
-- Shows commits ahead of fork point, decision count,
-- correction rate, and open merge request status.
-- ============================================================

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
)
LANGUAGE sql STABLE AS $$
  SELECT
    b.id                                                    AS branch_id,
    b.name                                                  AS branch_name,
    hc.hash                                                 AS head_commit_hash,
    fb.name                                                 AS forked_from_name,
    (
      SELECT count(*)
      FROM cvcs.commits cc
      WHERE cc.repository_id = p_repository_id
        AND cc.committed_at > COALESCE(
          (SELECT committed_at FROM cvcs.commits WHERE hash = b.forked_at_hash),
          '-infinity'::timestamptz
        )
        AND cc.id = b.head_commit_id
    )                                                       AS commits_since_fork,
    count(DISTINCT d.id)                                    AS total_decisions,
    count(DISTINCT co.id)                                   AS total_corrections,
    count(DISTINCT mr.id) FILTER (WHERE mr.status = 'open') AS open_mrs,
    hc.committed_at                                         AS last_commit_at
  FROM cvcs.branches b
  LEFT JOIN cvcs.commits   hc ON hc.id = b.head_commit_id
  LEFT JOIN cvcs.branches  fb ON fb.id = b.forked_from_id
  LEFT JOIN cvcs.decisions  d ON d.branch_id = b.id
  LEFT JOIN cvcs.corrections co ON co.decision_id = d.id
  LEFT JOIN cvcs.merge_requests mr
    ON mr.repository_id = p_repository_id
    AND (mr.source_branch_id = b.id OR mr.target_branch_id = b.id)
  WHERE b.repository_id = p_repository_id
  GROUP BY b.id, b.name, hc.hash, hc.committed_at, fb.name, b.forked_at_hash, b.head_commit_id
  ORDER BY hc.committed_at DESC NULLS LAST
$$;

COMMENT ON FUNCTION cvcs.branch_summary IS
  'At-a-glance view of all branches. Shows activity, correction pressure, and merge request status. Entry point for the branch graph UI.';
