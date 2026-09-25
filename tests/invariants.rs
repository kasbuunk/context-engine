//! M0 tests: the §4 invariants, exercised through the CLI (SPEC.md §6).

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use rusqlite::Connection;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const CE: &str = env!("CARGO_BIN_EXE_ce");

fn src() -> Value {
    json!({"type": "manual-export", "repeatability": "manual"})
}

fn llm() -> Value {
    json!({"type": "llm", "repeatability": "volatile", "model": "test-model",
           "prompt_hash": "0".repeat(64), "tool": "test", "tool_version": "0"})
}

fn sha256(data: &[u8]) -> String {
    Sha256::digest(data)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

struct Env {
    dir: tempfile::TempDir,
    db: PathBuf,
}

impl Env {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("ce.db");
        let env = Env { dir, db };
        env.ce(&["init"], "");
        env
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn run(&self, args: &[&str], stdin: impl AsRef<[u8]>) -> Output {
        let mut child = Command::new(CE)
            .arg("--db")
            .arg(&self.db)
            .args(args)
            .env_remove("CE_DB")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(stdin.as_ref())
            .unwrap();
        child.wait_with_output().unwrap()
    }

    /// Run ce, assert success, return the parsed JSON lines.
    fn ce(&self, args: &[&str], stdin: impl AsRef<[u8]>) -> Vec<Value> {
        let out = self.run(args, stdin);
        assert!(
            out.status.success(),
            "ce {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    fn one(&self, args: &[&str], stdin: impl AsRef<[u8]>) -> Value {
        let mut out = self.ce(args, stdin);
        assert_eq!(out.len(), 1, "{out:?}");
        out.pop().unwrap()
    }

    fn fails(&self, args: &[&str], stdin: impl AsRef<[u8]>) -> String {
        let out = self.run(args, stdin);
        assert!(!out.status.success(), "ce {args:?} unexpectedly succeeded");
        String::from_utf8_lossy(&out.stderr).into_owned()
    }

    fn text(&self, body: &str) -> String {
        let spec = src().to_string();
        hash(&self.one(&["ingest", "--stdin", "--spec", &spec], body))
    }

    fn synth(
        &self,
        body: &str,
        subjects: &[&str],
        contexts: &[&str],
        supersedes: Option<&str>,
    ) -> String {
        let spec = llm().to_string();
        let mut args = vec!["synth", "--spec", &spec, "--subject"];
        args.extend(subjects);
        if !contexts.is_empty() {
            args.push("--context");
            args.extend(contexts);
        }
        if let Some(s) = supersedes {
            args.extend(["--supersedes", s]);
        }
        hash(&self.one(&args, body))
    }

    fn conn(&self) -> Connection {
        Connection::open(&self.db).unwrap()
    }

    fn count(&self, table: &str) -> i64 {
        self.conn()
            .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
            .unwrap()
    }
}

fn hash(v: &Value) -> String {
    v["hash"].as_str().unwrap().to_owned()
}

// --- immutability --------------------------------------------------------------

#[test]
fn update_and_delete_fail() {
    let env = Env::new();
    let a = env.text("alpha");
    let b = env.synth("about alpha", &[&a], &[], None);
    let conn = env.conn();
    for stmt in [
        "UPDATE artifacts SET status='failed'",
        "DELETE FROM artifacts",
        "UPDATE edges SET role='context'",
        "DELETE FROM edges",
    ] {
        let err = conn.execute(stmt, []).expect_err(stmt).to_string();
        assert!(err.contains("immutable"), "{stmt}: {err}");
    }
    assert_eq!(env.count("artifacts"), 2);
    let edge: (String, String, String) = conn
        .query_row("SELECT from_hash, to_hash, role FROM edges", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .unwrap();
    assert_eq!(edge, (b, a, "subject".into()));
}

// --- hashing -------------------------------------------------------------------

#[test]
fn reingest_identical_content_is_noop() {
    let env = Env::new();
    let first = env.one(
        &["ingest", "--stdin", "--spec", &src().to_string()],
        "same bytes\n",
    );
    let path = env.path().join("renamed.md");
    std::fs::write(&path, "same bytes\n").unwrap();
    let git = json!({"type": "git-file", "repeatability": "stable"}).to_string();
    let again = env.one(&["ingest", path.to_str().unwrap(), "--spec", &git], "");
    assert_eq!(first["created"], true);
    assert_eq!(again["created"], false);
    assert_eq!(hash(&first), hash(&again));
    assert_eq!(hash(&first), sha256(b"same bytes\n"));
    assert_eq!(env.count("artifacts"), 1);
}

#[test]
fn failed_retrieval_is_stored_and_distinct_from_retry() {
    let env = Env::new();
    let spec = json!({"type": "grafana-query", "repeatability": "decaying",
                      "query": "rate(errors[5m])", "token_ref": "env:GRAFANA_TOKEN"})
    .to_string();
    let args = ["ingest", "--ref", "--spec", &spec, "--status", "failed"];
    let h1 = hash(&env.one(&args, ""));
    let h2 = hash(&env.one(&args, ""));
    assert_ne!(h1, h2);
    let conn = env.conn();
    let mut stmt = conn
        .prepare("SELECT hash, spec, created_at, status, payload FROM artifacts")
        .unwrap();
    let rows: Vec<(String, String, String, String, Option<String>)> = stmt
        .query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        })
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(rows.len(), 2);
    for (h, spec_json, created_at, status, payload) in rows {
        assert_eq!(status, "failed");
        assert_eq!(payload, None);
        // Invariant 2: recomputable as canonical_json(spec) || created_at.
        let canon = serde_json::from_str::<Value>(&spec_json)
            .unwrap()
            .to_string();
        assert_eq!(spec_json, canon);
        assert_eq!(h, sha256(format!("{canon}{created_at}").as_bytes()));
    }
}

#[test]
fn empty_stdin_is_stored_as_empty_not_collapsed() {
    let env = Env::new();
    let args = ["ingest", "--stdin", "--spec", &src().to_string()];
    let h1 = hash(&env.one(&args, ""));
    let h2 = hash(&env.one(&args, ""));
    assert_ne!(h1, h2);
    let statuses: Vec<String> = env
        .conn()
        .prepare("SELECT DISTINCT status FROM artifacts")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(statuses, ["empty"]);
}

#[test]
fn every_text_hash_is_recomputable() {
    let env = Env::new();
    let a = env.text("héllo wörld\r\nline two");
    env.synth("claim ✓", &[&a], &[], None);
    let conn = env.conn();
    let mut stmt = conn.prepare("SELECT hash, payload FROM artifacts").unwrap();
    let rows = stmt
        .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
        .unwrap();
    for row in rows {
        let (h, payload) = row.unwrap();
        assert_eq!(h, sha256(payload.as_bytes()));
    }
}

// --- blobs ---------------------------------------------------------------------

#[test]
fn binary_lands_at_fanout_path_and_matches_shasum() {
    let env = Env::new();
    let data: Vec<u8> = (0..=255u8).cycle().take(256 * 64).collect();
    let path = env.path().join("recording.wav");
    std::fs::write(&path, &data).unwrap();
    let out = env.one(
        &[
            "ingest",
            path.to_str().unwrap(),
            "--spec",
            &src().to_string(),
        ],
        "",
    );
    let h = hash(&out);
    let shasum = Command::new("shasum")
        .args(["-a", "256"])
        .arg(&path)
        .output()
        .unwrap();
    let shasum = String::from_utf8(shasum.stdout).unwrap();
    assert_eq!(h, shasum.split_whitespace().next().unwrap());
    let fanout = env.path().join("blobs").join(&h[..2]).join(&h[2..]);
    assert_eq!(out["blob"], json!(fanout));
    assert_eq!(std::fs::read(&fanout).unwrap(), data);
    // No leftover temp files from the atomic write.
    let names: Vec<_> = std::fs::read_dir(fanout.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    assert_eq!(names, [&h[2..]]);
    let (payload, blob_path, spec): (Option<String>, Option<String>, String) = env
        .conn()
        .query_row(
            "SELECT payload, blob_path, spec FROM artifacts WHERE hash=?",
            [&h],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .unwrap();
    assert_eq!(payload, None);
    assert_eq!(blob_path, None); // derivable from the hash
    assert_eq!(
        serde_json::from_str::<Value>(&spec).unwrap()["original_name"],
        "recording.wav"
    );
}

#[test]
fn text_file_has_no_blob() {
    let env = Env::new();
    let path = env.path().join("notes.vtt");
    std::fs::write(&path, "WEBVTT\n\n00:00.000 --> 00:01.000\nhello\n").unwrap();
    let h = hash(&env.one(
        &[
            "ingest",
            path.to_str().unwrap(),
            "--spec",
            &src().to_string(),
        ],
        "",
    ));
    assert!(!env.path().join("blobs").join(&h[..2]).exists());
    assert_eq!(env.ce(&["search", "hello"], "").len(), 1);
}

// --- synthesis -----------------------------------------------------------------

#[test]
fn synthesis_without_subject_is_rejected() {
    let env = Env::new();
    let err = env.fails(&["synth", "--spec", &llm().to_string()], "orphan claim");
    assert!(err.contains("subject"), "{err}");
    assert_eq!(env.count("artifacts"), 0);
}

#[test]
fn synthesis_is_atomic_with_its_edges() {
    let env = Env::new();
    let a = env.text("real source");
    let missing = "f".repeat(64);
    env.fails(
        &[
            "synth",
            "--spec",
            &llm().to_string(),
            "--subject",
            &a,
            "--context",
            &missing,
        ],
        "claim with a bad footnote",
    );
    assert_eq!(env.count("artifacts"), 1);
    assert_eq!(env.count("edges"), 0);
}

#[test]
fn spec_requires_type_and_repeatability() {
    let env = Env::new();
    for spec in [
        json!({}),
        json!({"type": "x"}),
        json!({"type": "x", "repeatability": "maybe"}),
    ] {
        env.fails(&["ingest", "--stdin", "--spec", &spec.to_string()], "x");
    }
    assert_eq!(env.count("artifacts"), 0);
}

// --- staleness and supersession ------------------------------------------------

#[test]
fn stale_flags_synthesis_after_subject_superseded() {
    let env = Env::new();
    let v1 = env.text("ticket v1");
    let s = env.synth("summary of ticket", &[&v1], &[], None);
    assert!(env.ce(&["stale"], "").is_empty());
    let v2 = env.text("ticket v2");
    env.one(&["supersede", &v2, &v1], "");
    assert_eq!(
        env.ce(&["stale"], ""),
        [json!({"synthesis": s, "superseded_subject": v1})]
    );
    // Rebuilding the synthesis on v2 and superseding the old one clears it.
    env.synth("summary of ticket v2", &[&v2], &[], Some(&s));
    assert!(env.ce(&["stale"], "").is_empty());
}

#[test]
fn context_supersession_is_not_stale() {
    let env = Env::new();
    let (subj, ctx) = (env.text("subject"), env.text("glossary v1"));
    env.synth("claim", &[&subj], &[&ctx], None);
    let v2 = env.text("glossary v2");
    env.one(&["supersede", &v2, &ctx], "");
    assert!(env.ce(&["stale"], "").is_empty());
}

#[test]
fn supersede_cycle_rejected() {
    let env = Env::new();
    let (a, b) = (env.text("a"), env.text("b"));
    env.one(&["supersede", &b, &a], "");
    env.fails(&["supersede", &a, &b], "");
}

#[test]
fn search_returns_current_only() {
    let env = Env::new();
    let v1 = env.text("the quarterly budget draft");
    assert_eq!(env.ce(&["search", "budget"], "").len(), 1);
    let v2 = env.text("the quarterly budget final");
    env.one(&["supersede", &v2, &v1], "");
    let hits: Vec<String> = env.ce(&["search", "budget"], "").iter().map(hash).collect();
    assert_eq!(hits, [v2]);
}

// --- walks ---------------------------------------------------------------------

struct Chain {
    env: Env,
    rec: String,
    transcript: String,
    gloss: String,
    fact: String,
    adr: String,
}

fn chain() -> Chain {
    let env = Env::new();
    let spec = json!({"type": "teams-recording", "repeatability": "manual"}).to_string();
    let rec = hash(&env.one(&["ingest", "--ref", "--spec", &spec], ""));
    let transcript = env.synth("we chose sqlite because", &[&rec], &[], None);
    let gloss = env.text("glossary: ADR = architecture decision record");
    let fact = env.synth("fact: sqlite chosen", &[&transcript], &[&gloss], None);
    let adr = env.synth("ADR-1: use sqlite", &[&fact], &[], None);
    Chain {
        env,
        rec,
        transcript,
        gloss,
        fact,
        adr,
    }
}

#[test]
fn show_prints_full_footnote_chain() {
    let c = chain();
    let d = c.env.one(&["show", &c.adr], "");
    assert_eq!(d["kind"], "synthesis");
    assert_eq!(d["edges_out"], json!([{"hash": c.fact, "role": "subject"}]));
    let got: BTreeSet<(String, String, String, i64)> = d["footnotes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| {
            let s = |k: &str| f[k].as_str().unwrap().to_owned();
            (
                s("hash"),
                s("parent"),
                s("via"),
                f["depth"].as_i64().unwrap(),
            )
        })
        .collect();
    let want: BTreeSet<_> = [
        (c.fact.clone(), c.adr.clone(), "subject".to_owned(), 1),
        (
            c.transcript.clone(),
            c.fact.clone(),
            "subject".to_owned(),
            2,
        ),
        (c.gloss.clone(), c.fact.clone(), "context".to_owned(), 2),
        (c.rec.clone(), c.transcript.clone(), "subject".to_owned(), 3),
    ]
    .into();
    assert_eq!(got, want);
    let rec = c.env.one(&["show", &c.rec], "");
    assert_eq!(
        rec["edges_in"],
        json!([{"hash": c.transcript, "role": "subject"}])
    );
}

#[test]
fn up_reaches_primary_source() {
    let c = chain();
    let up = c.env.ce(&["up", &c.adr[..8]], "");
    let last = up.last().unwrap();
    assert_eq!(hash(last), c.rec);
    assert_eq!(last["kind"], "source");
}

#[test]
fn down_is_contamination_trace() {
    let c = chain();
    let down: BTreeMap<String, Value> = c
        .env
        .ce(&["down", &c.gloss], "")
        .iter()
        .map(|r| (hash(r), r["via"].clone()))
        .collect();
    let want: BTreeMap<String, Value> = [
        (c.gloss.clone(), Value::Null),
        (c.fact.clone(), json!("context")),
        (c.adr.clone(), json!("subject")),
    ]
    .into();
    assert_eq!(down, want);
}
