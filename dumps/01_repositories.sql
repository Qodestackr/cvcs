CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE SCHEMA IF NOT EXISTS cvcs;

-- One repository = one cognitive system being versioned.
-- slug is the stable external identifier, never changes.
CREATE TABLE cvcs.repositories (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text        NOT NULL UNIQUE,
  name        text        NOT NULL,
  description text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (slug ~ '^[a-z0-9][a-z0-9\-]*[a-z0-9]$')
);

-- NOTE: bootstrap_repository() is defined in 05_collaboration.sql
-- because it inserts into cvcs.branches, which is created there.
-- Run schema files in order: 01 ... 05.