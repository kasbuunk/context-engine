-- Verbatim from SPEC.md §3. The database is the library.
PRAGMA foreign_keys = ON;

CREATE TABLE artifacts (
  hash       TEXT PRIMARY KEY,                       -- sha256 hex, see §2.4
  kind       TEXT NOT NULL CHECK (kind IN ('source','synthesis')),
  spec       TEXT NOT NULL CHECK (json_valid(spec)), -- the recipe to do it again
  payload    TEXT,                                   -- searchable text, or NULL
  blob_path  TEXT,                                   -- NULL = derivable from hash, or no bytes
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  status     TEXT NOT NULL DEFAULT 'ok'
             CHECK (status IN ('ok','empty','partial','failed'))
);

CREATE TABLE edges (
  from_hash TEXT NOT NULL REFERENCES artifacts(hash),
  to_hash   TEXT NOT NULL REFERENCES artifacts(hash),
  role      TEXT NOT NULL CHECK (role IN ('subject','context','supersedes')),
  PRIMARY KEY (from_hash, to_hash, role),
  CHECK (from_hash <> to_hash)
);
CREATE INDEX edges_to ON edges(to_hash, role);

-- Immutability: nothing is ever updated or deleted.
CREATE TRIGGER artifacts_no_update BEFORE UPDATE ON artifacts
  BEGIN SELECT RAISE(ABORT, 'artifacts are immutable'); END;
CREATE TRIGGER artifacts_no_delete BEFORE DELETE ON artifacts
  BEGIN SELECT RAISE(ABORT, 'artifacts are immutable'); END;
CREATE TRIGGER edges_no_update BEFORE UPDATE ON edges
  BEGIN SELECT RAISE(ABORT, 'edges are immutable'); END;
CREATE TRIGGER edges_no_delete BEFORE DELETE ON edges
  BEGIN SELECT RAISE(ABORT, 'edges are immutable'); END;

-- Full-text search over payloads.
CREATE VIRTUAL TABLE artifacts_fts USING fts5(
  payload, content='artifacts', content_rowid='rowid'
);
CREATE TRIGGER artifacts_fts_insert AFTER INSERT ON artifacts
  WHEN new.payload IS NOT NULL
  BEGIN INSERT INTO artifacts_fts(rowid, payload) VALUES (new.rowid, new.payload); END;

-- Current = not superseded by anything.
CREATE VIEW current_artifacts AS
  SELECT a.* FROM artifacts a
  WHERE NOT EXISTS (
    SELECT 1 FROM edges e WHERE e.to_hash = a.hash AND e.role = 'supersedes'
  );

-- Stale = a current synthesis whose subject has been superseded.
CREATE VIEW stale_syntheses AS
  SELECT DISTINCT s.hash AS synthesis, e.to_hash AS superseded_subject
  FROM current_artifacts s
  JOIN edges e ON e.from_hash = s.hash AND e.role = 'subject'
  WHERE s.kind = 'synthesis'
    AND EXISTS (SELECT 1 FROM edges x
                WHERE x.to_hash = e.to_hash AND x.role = 'supersedes');
