-- ============================================================
-- CVCS SCHEMA: 01_repositories.sql
--
-- The namespace boundary. One repository = one agent system
-- or one organizational unit being versioned.
--
-- Everything else in the schema is scoped to a repository.
-- This is the tenant isolation boundary for the MVP.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS cvcs;

-- ============================================================
-- REPOSITORIES
--
-- The root anchor. A repository represents a single cognitive
-- system being versioned — one insurance underwriting agent,
-- one customer support agent, one order management system.
--
-- slug is the stable external identifier. It never changes.
-- Use it in CLI commands: cvcs commit --repo acme-underwriting
-- ============================================================

CREATE TABLE cvcs.repositories (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text        NOT NULL UNIQUE,
  name        text        NOT NULL,
  description text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (slug ~ '^[a-z0-9][a-z0-9\-]*[a-z0-9]$')
);

COMMENT ON TABLE cvcs.repositories IS
  'The namespace boundary. One repo = one cognitive system being versioned.';

-- ============================================================
-- BOOTSTRAP FUNCTION
--
-- Creates a repository and its initial main branch atomically.
-- The main branch starts with no commits (head_commit_id null)
-- until the first cognitive state is committed.
--
-- Called once at system setup per agent/org unit.
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

  -- main branch always exists; head starts null (no commits yet)
  INSERT INTO cvcs.branches (repository_id, name)
  VALUES (v_repo_id, 'main');

  RETURN v_repo_id;
END;
$$;

COMMENT ON FUNCTION cvcs.bootstrap_repository IS
  'Creates a repository and its initial main branch atomically. Call once per agent system.';