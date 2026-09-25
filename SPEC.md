---
created: 2026-09-25
updated: 2026-09-25
tags: [context-engine, coherence, dev, spec]
type: reference
author: claude
derived_from: "[[2026-09-25 voice chat — context engine with source criticism]]"
---

# Context engine with source criticism: bootstrap spec

> **How to use this file.** Copy it into an empty repo as `SPEC.md` (or `CLAUDE.md`). Then start an agent there with: *"Read SPEC.md. Build milestone M0 only, then stop and show me."* Everything the agent needs is in this file. The design reasoning lives in the vault note linked in `derived_from`.

## 1. Purpose

A **context engine** captures the context a team, or a person, uses to make decisions, so that an AI can serve that context back to humans. Humans still decide.

Its differentiator is **source criticism**, the method of Ranke and Droysen:

- every claim in the store can be traced to what it was built from;
- evidence is kept apart from interpretation;
- a bad claim can be traced downstream to everything it contaminated.

This repo ships **a schema, this spec, and a small reference implementation**. It is not an application, and it does not fetch data. Callers such as a cron script, Airbyte, an agent or an MCP client fetch the data and hand it in along with its provenance. The spec is the durable part. The code is disposable and can be regenerated in any language.

## 2. Model

Everything is an **artifact**. Artifacts are **immutable**: a new version is a new artifact that *supersedes* the old one. SQLite triggers enforce this.

| Table | Columns |
|---|---|
| `artifacts` | `hash`, `kind`, `spec`, `payload`, `blob_path`, `created_at`, `status` |
| `edges` | `from_hash`, `to_hash`, `role` |

### 2.1 `kind`: source or synthesis

- **source**: its `spec` points **outside** the store. Examples: a Git path at a commit, a Grafana query, a Graph API call, or a human procedure ("export the transcript from Teams via the browser").
- **synthesis**: its `spec` points **inside** the store. It is made from artifacts the store already holds, plus a model, prompt and tool version (or a deterministic extractor and its version). Enrichment of a single source is simply a synthesis with one subject.

The two kinds share one table; think of it as a sum type flattened into rows. Edges, walks and staleness treat both kinds the same, so don't split the table.

### 2.2 `spec`: the method

The spec is JSON, and its shape depends on the source type. **It is the recipe for doing the work again.** It is not an audit log. It MUST contain enough to reproduce the retrieval or the synthesis, or to state honestly why that isn't possible.

Required keys:

- `type`: a free string, for example `git-file`, `grafana-query`, `teams-transcript`, `manual-export`, `llm`, `extractor`.
- `repeatability`: one of the values below. This is a mechanical fact about the endpoint, not a judgement.

| `repeatability` | Meaning | Example |
|---|---|---|
| `stable` | Re-running returns identical bytes forever | A Git blob at a commit |
| `decaying` | Can be re-run until the data expires | A log query with 30-day retention |
| `volatile` | Can be re-run, but the result will differ | A live API call |
| `manual` | A human procedure | A browser export |

Recommended keys:

- `retrieved_at`
- `original_name`: the original filename lives *here*, not in the payload. That keeps filenames out of the full-text index.
- `expires_at` for `decaying` sources.
- For a synthesis: `model`, `prompt_hash`, `tool`, `tool_version`.

Never store a credential value in the spec. Store a *reference* to one instead, such as an env var name or a 1Password item name.

### 2.3 Content: `payload` and `blob_path`

- **Text you want searchable** goes in `payload`, which is indexed with FTS5. A `.vtt` file or a markdown file has no separate blob, because its payload *is* the file.
- **Binary content** (`.wav`, images, PDFs) gets `payload = NULL`. The bytes are stored at `blobs/<first 2 hex chars>/<remaining hex>`, which is Git-style fanout. Searchable text for a binary comes from a downstream synthesis, such as a transcription or a caption.
- `blob_path` stays NULL when the path can be derived from the hash. Set it only when the bytes live **elsewhere**, such as a network share or S3, because they are too large to copy.

### 2.4 `hash`

The hash is lowercase hex sha256, computed as follows:

1. If the artifact has content (payload text or blob bytes), hash **the content only**. Re-ingesting identical content under a new name is a no-op.
2. If it has no content, as with a pure reference or a failed retrieval, hash `canonical_json(spec) || created_at`. Two failed attempts are two pieces of evidence and must not collide.

Canonical JSON means sorted keys, no insignificant whitespace, and UTF-8.

### 2.5 `status`

The allowed values are `ok`, `empty`, `partial` and `failed`. An empty or failed retrieval is still **stored**, because it is evidence and it stops the same query being re-run forever. Syntheses are normally `ok`.

### 2.6 Edges

The edge lives on the artifact **making the claim**, and points **at** what it relies on or replaces. A new artifact therefore never needs to touch existing rows.

| `role` | Meaning | Test |
|---|---|---|
| `subject` | What this artifact makes claims **about** | If the target were wrong, this artifact would be **wrong** |
| `context` | What informed it without being its topic, such as a glossary, background meetings or a prompt | If the target were wrong, this artifact would be **poorer**, not wrong |
| `supersedes` | This artifact replaces the target, e.g. a new Jira version or a revised theory | "Current" means nothing supersedes it |

- A **source** normally has no subject or context edges. It may have a `supersedes` edge to its previous version.
- Every new version of anything supersedes its predecessor. Rebuilds and revised understanding are treated the same way. Nothing is deleted: superseded artifacts are **forgotten by default and remembered on request**.
- **Subject vs context is provisional.** Populate it on every write. Only `stale_syntheses` reads it for now. Whether the distinction earns its keep will be decided by the M2 vertical slice (§6).
- **Never hard-code semantics** in the schema: no people, teams, services, authorship or trust fields. A judgement such as "this source is unreliable" is itself a **synthesis** with a `subject` edge to the thing it judges. That way judgements carry their own provenance and can themselves be superseded.
- New roles need a behaviour to justify them. A role is admitted only when traversing it answers a query that search cannot.

## 3. Schema

The database is the library. Views carry the norms, so every language gets them for free just by querying.

```sql
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
```

This was tested on SQLite 3.51 (2026-09-25): the immutability triggers abort updates, and the FTS index, `current_artifacts` and `stale_syntheses` all return correct results.

### Canonical queries

These are parameterised queries, not views.

```sql
-- Downstream / contamination trace: everything built on :hash, transitively.
WITH RECURSIVE down(hash, via, depth) AS (
  SELECT :hash, NULL, 0
  UNION
  SELECT e.from_hash, e.role, d.depth + 1
  FROM edges e JOIN down d ON e.to_hash = d.hash
  WHERE e.role IN ('subject','context')
)
SELECT * FROM down;
-- Blast radius: rows reached only via 'context' are probably salvageable;
-- a chain of 'subject' edges is load-bearing.

-- Upstream / the footnote walk: what :hash rests on, transitively.
WITH RECURSIVE up(hash, via, depth) AS (
  SELECT :hash, NULL, 0
  UNION
  SELECT e.to_hash, e.role, u.depth + 1
  FROM edges e JOIN up u ON e.from_hash = u.hash
  WHERE e.role IN ('subject','context')
)
SELECT * FROM up;

-- Latest insights of the last week.
SELECT * FROM current_artifacts
WHERE kind = 'synthesis' AND created_at >= strftime('%Y-%m-%dT%H:%M:%fZ','now','-7 days');

-- Search, current only. Join via the base table: a view exposes no rowid.
SELECT a.* FROM artifacts_fts f
JOIN artifacts a ON a.rowid = f.rowid
JOIN current_artifacts c ON c.hash = a.hash
WHERE artifacts_fts MATCH :query;
```

## 4. Invariants an implementation MUST keep

1. No UPDATE and no DELETE, ever. The triggers enforce this, and code must not work around them.
2. `hash` is recomputable from the stored content (§2.4). An implementation that stores bytes it did not hash is wrong.
3. Writing a blob happens **before** its artifact row, and is atomic: write to a temp file, fsync, then rename into `blobs/`.
4. A synthesis row and all its edges are inserted in **one transaction**. A synthesis without its edges is an unfootnoted claim.
5. Every synthesis has at least one `subject` edge.
6. Ingestion is **deterministic** and runs no LLM in the loop. Agents may *write* connectors, but connectors run as plain code. LLM work happens only in syntheses, and those record model and prompt in their `spec`.
7. The store never holds credentials, only references to them.

## 5. Reference implementation: surface

It is small on purpose. Choose any language; don't assume Go. A single-file CLI over the SQLite database is enough.

```
ce init [--db PATH]                          create db + blobs/ from §3
ce ingest FILE --spec JSON                   source from a file; text → payload, binary → blob
ce ingest --stdin --spec JSON                source from piped text
ce ingest --ref --spec JSON [--status S]     content-less source (pointer or failed retrieval)
ce synth --spec JSON --subject H... [--context H...] [--supersedes H] < payload
ce supersede NEW OLD                         add a supersedes edge
ce show HASH                                 row + edges both directions (+ blob path)
ce up HASH / ce down HASH                    the two walks from §3
ce search QUERY                              FTS over current artifacts
ce stale                                     rows from stale_syntheses
```

Each command prints the hash (or the rows) as JSON lines, so its output can be piped into other tools. An MCP server over these same verbs is a later, optional wrapper, and it would feed, not fetch.

## 6. Milestones

Stop after each one and show the result.

**M0: the store.** Build `ce init`, `ingest` (file, stdin, ref), `synth`, `supersede`, `show`, `up`, `down`, `search` and `stale`. Write tests for the invariants in §4: an UPDATE fails; re-ingesting identical content is a no-op that returns the same hash; a failed retrieval is stored and its hash is distinct from a retry's; a binary lands at the fanout path and its hash matches `shasum -a 256`; a synthesis without a subject is rejected; `stale` flags a synthesis after its subject is superseded.
*Done when:* all the tests pass and `ce show` on a synthesis prints its full footnote chain.

**M1: first real sources.** Ingest a Git repo at a commit. Each file becomes a source with `{type: git-file, repo, commit, path, repeatability: stable}`. Re-running at the same commit adds nothing. Running at a new commit adds only the changed files, each superseding its previous version.
*Done when:* two commits have been ingested, `ce stale` output is empty (because no syntheses exist yet), and the count of new rows equals the output of `git diff --name-only`.

**M2: the vertical slice.** This is the milestone that tests the model. Take **one real decision** (an ADR in the work instance, or a vault decision note in the personal one) and walk it by hand down to its evidence: the ADR, the facts it cites, the source snippets those facts point to, and the interview or recording that explains *why*. Model only that chain. Record, for every edge, whether subject or context was the obvious choice or a toss-up.
*Done when:* `ce up <adr>` reaches a primary source, and there is a short written verdict on whether subject vs context divided cleanly. That verdict decides whether §2.6's provisional roles stay.

**M3: artifact #1.** Ingest the conversation this design came from, a claude.ai voice chat exported by hand. Its spec is `{type: manual-export, procedure: "claude.ai → share → copy read-only view → paste", repeatability: manual}`, and a structured summary is added as a synthesis with it as subject. This proves that `spec` can carry a human procedure.

**Out of scope until M2 has passed:** connectors (Slack, Teams, Confluence, Grafana, Datadog), schedulers and triggers, embeddings, any UI, any server.

## 7. Deployment notes

- There are **two separate instances that never merge**: the work VM, run from the monorepo, where the monorepo's existing skills and scripts become retrieval specs; and the homelab, for the personal corpus. Never use one engine with a tenant column.
- Git is the **control plane**: human-authored material such as ADRs, designs, skills and scripts. The store is the **observation plane**: captured and derived material, which references Git by commit hash.
- `blobs/` and the `.db` file are data, not code. Keep them out of this repo's Git. Back them up like any other data; the spec says nothing about backups.

## 8. Open questions (decide with evidence, not in advance)

- Does **subject vs context** survive M2? If every edge was a toss-up, collapse to one unlabelled role plus `supersedes`.
- **Hash identity for syntheses:** two different methods that produce byte-identical output currently collide, because identity is content-only. Is that acceptable, or should a synthesis's hash include its `spec`?
- Is an **ingestion event** an artifact of its own? It is parked as too meta for now.
- Which roles should **prompt and glossary artifacts** get? The default is `context` by the test in §2.6, but a bad prompt can make an artifact wrong, not just poorer.
- **Forgetting:** should payloads of long-superseded artifacts ever be pruned while their rows and edges are kept, the way log aggregates outlive the logs they summarise?
