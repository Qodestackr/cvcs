# Database schema

`schema/postgres/` is the ordered server-side projection of the CVCS domain. The files are
numbered by dependency and must be applied in ascending order:

1. repositories and tenant boundaries;
2. content-addressed blobs and commits;
3. decisions and causal replays;
4. corrections, detected patterns, and ratified rules;
5. branches, merge review, and collaboration helpers.

The local Python kernel does not require Postgres. Its `.cvcs/ledger.db` is a portable
single-user projection. Postgres is the intended collaborative control-plane projection;
both must ultimately consume the same canonical event vocabulary.

These are schema modules rather than ad-hoc dumps. Before the first networked release they
will be wrapped in tracked, forward-only migrations with event-to-projection consumers.
Until then, keeping the modules ordered and independently reviewable makes schema intent
explicit without pretending an unreleased migration history already exists.

