//! ce: reference CLI for the context engine (SPEC.md §5).
//!
//! The schema lives in schema.sql and is compiled in; the database carries the
//! norms (triggers, views). This file only keeps the invariants SQL cannot
//! express on its own (§4: hashing, blob atomicity, subject edges,
//! single-transaction synthesis).
//!
//! Every command prints JSON lines on stdout. Errors go to stderr, exit code 1.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::{Parser, Subcommand};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

const SCHEMA: &str = include_str!("../schema.sql");
const REPEATABILITY: [&str; 4] = ["decaying", "manual", "stable", "volatile"];
const STATUSES: [&str; 4] = ["ok", "empty", "partial", "failed"];

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

macro_rules! bail {
    ($($arg:tt)*) => { return Err(format!($($arg)*).into()) };
}

// --- hashing (§2.4) ----------------------------------------------------------

/// Sorted keys, no insignificant whitespace, UTF-8. serde_json's default map
/// is a BTreeMap, so keys serialise sorted; `preserve_order` must stay off.
fn canonical_json(v: &Value) -> String {
    v.to_string()
}

fn sha256(data: &[u8]) -> String {
    Sha256::digest(data)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn ref_hash(spec_json: &str, created_at: &str) -> String {
    sha256(format!("{spec_json}{created_at}").as_bytes())
}

/// Microseconds, not the schema default's milliseconds: two content-less
/// retrievals in the same millisecond must still get distinct hashes.
fn now() -> String {
    let d = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock before 1970");
    format_utc(d.as_secs() as i64, d.subsec_micros())
}

fn format_utc(secs: i64, micros: u32) -> String {
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}.{micros:06}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

// --- store -------------------------------------------------------------------

struct Store {
    db_path: PathBuf,
    blob_root: PathBuf,
}

impl Store {
    fn new(db: &Path) -> Result<Self> {
        let db_path = std::path::absolute(db)?;
        let blob_root = db_path.parent().unwrap_or(Path::new("/")).join("blobs");
        Ok(Store { db_path, blob_root })
    }

    fn connect(&self) -> Result<Connection> {
        if !self.db_path.exists() {
            bail!(
                "no database at {}; run `ce init` first",
                self.db_path.display()
            );
        }
        self.open()
    }

    fn open(&self) -> Result<Connection> {
        let conn = Connection::open(&self.db_path)?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        Ok(conn)
    }

    fn init(&self) -> Result<Value> {
        let conn = self.open()?;
        let exists: bool = conn.query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='artifacts'",
            [],
            |r| r.get(0),
        )?;
        if !exists {
            conn.execute_batch(SCHEMA)?;
        }
        fs::create_dir_all(&self.blob_root)?;
        Ok(json!({"db": self.db_path, "blobs": self.blob_root, "created": !exists}))
    }

    fn blob_file(&self, h: &str) -> PathBuf {
        self.blob_root.join(&h[..2]).join(&h[2..])
    }

    /// Invariant 3: temp file, fsync, rename; before the row exists.
    fn write_blob(&self, h: &str, data: &[u8]) -> Result<PathBuf> {
        let dest = self.blob_file(h);
        if dest.exists() {
            return Ok(dest);
        }
        let dir = dest.parent().expect("fanout dir");
        fs::create_dir_all(dir)?;
        let tmp = dir.join(format!(".tmp-{}-{}", std::process::id(), now()));
        let result = (|| -> io::Result<()> {
            let mut f = OpenOptions::new().write(true).create_new(true).open(&tmp)?;
            f.write_all(data)?;
            f.sync_all()?;
            fs::rename(&tmp, &dest)?;
            File::open(dir)?.sync_all()
        })();
        if result.is_err() {
            let _ = fs::remove_file(&tmp);
        }
        result?;
        Ok(dest)
    }

    /// Full hash, or a unique prefix of at least 4 hex chars.
    fn resolve(&self, conn: &Connection, r: &str) -> Result<String> {
        let r = r.trim().to_lowercase();
        if !r.chars().all(|c| c.is_ascii_hexdigit()) {
            bail!("not a hash: {r:?}");
        }
        if r.len() == 64 {
            let found = conn
                .query_row("SELECT 1 FROM artifacts WHERE hash=?", [&r], |_| Ok(()))
                .optional()?;
            return match found {
                Some(()) => Ok(r),
                None => bail!("no artifact {r}"),
            };
        }
        if r.len() < 4 {
            bail!("hash prefix too short: {r:?}");
        }
        let mut stmt = conn.prepare("SELECT hash FROM artifacts WHERE hash LIKE ? || '%'")?;
        let rows: Vec<String> = stmt
            .query_map([&r], |row| row.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        match rows.as_slice() {
            [h] => Ok(h.clone()),
            [] => bail!("no artifact {r:?}"),
            _ => bail!("ambiguous artifact {r:?}"),
        }
    }

    // -- writes ---------------------------------------------------------------

    /// Insert unless the hash already exists. Returns true if inserted.
    fn insert(
        conn: &Connection,
        h: &str,
        kind: &str,
        spec_json: &str,
        payload: Option<&str>,
        created_at: &str,
        status: &str,
    ) -> Result<bool> {
        let n = conn.execute(
            "INSERT OR IGNORE INTO artifacts \
             (hash, kind, spec, payload, blob_path, created_at, status) \
             VALUES (?, ?, ?, ?, NULL, ?, ?)",
            params![h, kind, spec_json, payload, created_at, status],
        )?;
        Ok(n == 1)
    }

    fn ingest_text(&self, spec: &Value, text: &str, status: &str) -> Result<Value> {
        let h = sha256(text.as_bytes());
        let conn = self.connect()?;
        let created = Self::insert(
            &conn,
            &h,
            "source",
            &canonical_json(spec),
            Some(text),
            &now(),
            status,
        )?;
        Ok(json!({"hash": h, "created": created}))
    }

    fn ingest_blob(&self, spec: &Value, data: &[u8], status: &str) -> Result<Value> {
        let h = sha256(data);
        let conn = self.connect()?;
        let blob = self.write_blob(&h, data)?;
        let created = Self::insert(
            &conn,
            &h,
            "source",
            &canonical_json(spec),
            None,
            &now(),
            status,
        )?;
        Ok(json!({"hash": h, "created": created, "blob": blob}))
    }

    fn ingest_ref(&self, spec: &Value, status: &str) -> Result<Value> {
        let spec_json = canonical_json(spec);
        let conn = self.connect()?;
        loop {
            // A new created_at on the (unlikely) same-microsecond clash.
            let created_at = now();
            let h = ref_hash(&spec_json, &created_at);
            if Self::insert(&conn, &h, "source", &spec_json, None, &created_at, status)? {
                return Ok(json!({"hash": h, "created": true}));
            }
        }
    }

    fn synth(
        &self,
        spec: &Value,
        text: &str,
        subjects: &[String],
        contexts: &[String],
        supersedes: Option<&str>,
    ) -> Result<Value> {
        if subjects.is_empty() {
            bail!("a synthesis needs at least one --subject (§4.5)");
        }
        let h = sha256(text.as_bytes());
        let mut conn = self.connect()?;
        let mut edges = Vec::new();
        for s in subjects {
            edges.push((self.resolve(&conn, s)?, "subject"));
        }
        for c in contexts {
            edges.push((self.resolve(&conn, c)?, "context"));
        }
        if let Some(s) = supersedes {
            edges.push((self.resolve(&conn, s)?, "supersedes"));
        }
        // Dropping the transaction without commit rolls it back.
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if !Self::insert(
            &tx,
            &h,
            "synthesis",
            &canonical_json(spec),
            Some(text),
            &now(),
            "ok",
        )? {
            // §8 open question: content-only identity. The existing claim
            // keeps its own footnotes; we do not graft new ones onto it.
            eprintln!("ce: identical content already stored as {h}; no new edges added");
            return Ok(json!({"hash": h, "created": false}));
        }
        for (target, role) in &edges {
            if *target == h {
                bail!("a synthesis cannot reference itself");
            }
            if *role == "supersedes" {
                check_supersede_cycle(&tx, &h, target)?;
            }
            tx.execute(
                "INSERT OR IGNORE INTO edges VALUES (?, ?, ?)",
                params![h, target, role],
            )?;
        }
        tx.commit()?;
        Ok(json!({"hash": h, "created": true}))
    }

    fn supersede(&self, new: &str, old: &str) -> Result<Value> {
        let mut conn = self.connect()?;
        let (new, old) = (self.resolve(&conn, new)?, self.resolve(&conn, old)?);
        if new == old {
            bail!("an artifact cannot supersede itself");
        }
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        check_supersede_cycle(&tx, &new, &old)?;
        let n = tx.execute(
            "INSERT OR IGNORE INTO edges VALUES (?, ?, 'supersedes')",
            params![new, old],
        )?;
        tx.commit()?;
        Ok(json!({"from": new, "to": old, "role": "supersedes", "created": n == 1}))
    }

    // -- reads ----------------------------------------------------------------

    fn walk(&self, conn: &Connection, dir: Walk, h: &str) -> Result<Vec<Value>> {
        let mut stmt = conn.prepare(dir.sql())?;
        let rows = stmt.query_map([h], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Option<String>>(1)?,
                r.get::<_, Option<String>>(2)?,
                r.get::<_, i64>(3)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (hash, parent, via, depth) = row?;
            let mut d = brief(conn, &hash)?;
            d.insert("hash".into(), json!(hash));
            d.insert("parent".into(), json!(parent));
            d.insert("via".into(), json!(via));
            d.insert("depth".into(), json!(depth));
            out.push(Value::Object(d));
        }
        Ok(out)
    }

    fn show(&self, r: &str) -> Result<Value> {
        let conn = self.connect()?;
        let h = self.resolve(&conn, r)?;
        let (kind, spec, payload, blob_path, created_at, status) = conn.query_row(
            "SELECT kind, spec, payload, blob_path, created_at, status \
             FROM artifacts WHERE hash=?",
            [&h],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                ))
            },
        )?;
        let mut d = Map::new();
        d.insert("hash".into(), json!(h));
        d.insert("kind".into(), json!(kind));
        d.insert("spec".into(), serde_json::from_str(&spec)?);
        d.insert("created_at".into(), json!(created_at));
        d.insert("status".into(), json!(status));
        d.insert("current".into(), json!(is_current(&conn, &h)?));
        d.insert("blob_path".into(), json!(blob_path));
        if let Some(p) = &blob_path {
            d.insert("blob_file".into(), json!(p));
        } else if payload.is_none() {
            let f = self.blob_file(&h);
            if f.exists() {
                d.insert("blob_file".into(), json!(f));
            }
        }
        d.insert("payload".into(), json!(payload));
        d.insert(
            "edges_out".into(),
            edge_list(
                &conn,
                "SELECT to_hash, role FROM edges WHERE from_hash=? ORDER BY role, to_hash",
                &h,
            )?,
        );
        d.insert(
            "edges_in".into(),
            edge_list(
                &conn,
                "SELECT from_hash, role FROM edges WHERE to_hash=? ORDER BY role, from_hash",
                &h,
            )?,
        );
        let mut footnotes = self.walk(&conn, Walk::Up, &h)?;
        footnotes.remove(0);
        d.insert("footnotes".into(), Value::Array(footnotes));
        Ok(Value::Object(d))
    }

    fn search(&self, query: &str) -> Result<Vec<Value>> {
        let conn = self.connect()?;
        let mut stmt = conn.prepare(
            "SELECT a.hash, a.kind, a.spec, a.status, a.created_at, \
                    snippet(artifacts_fts, 0, '[', ']', '…', 12) \
             FROM artifacts_fts f \
             JOIN artifacts a ON a.rowid = f.rowid \
             JOIN current_artifacts c ON c.hash = a.hash \
             WHERE artifacts_fts MATCH ? \
             ORDER BY rank",
        )?;
        let rows = stmt.query_map([query], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
                r.get::<_, String>(5)?,
            ))
        });
        let rows = rows.and_then(|it| it.collect::<rusqlite::Result<Vec<_>>>());
        let rows = rows.map_err(|e| format!("bad search query: {e}"))?;
        rows.into_iter()
            .map(|(hash, kind, spec, status, created_at, snippet)| {
                Ok(json!({
                    "hash": hash, "kind": kind, "spec": serde_json::from_str::<Value>(&spec)?,
                    "status": status, "created_at": created_at, "snippet": snippet,
                }))
            })
            .collect()
    }

    fn stale(&self) -> Result<Vec<Value>> {
        let conn = self.connect()?;
        let mut stmt = conn.prepare(
            "SELECT synthesis, superseded_subject FROM stale_syntheses \
             ORDER BY synthesis, superseded_subject",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(json!({"synthesis": r.get::<_, String>(0)?,
                      "superseded_subject": r.get::<_, String>(1)?}))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

#[derive(Clone, Copy)]
enum Walk {
    Up,
    Down,
}

impl Walk {
    /// The §3 walks, extended with the parent each row was reached from so a
    /// chain can be printed as a tree. UNION on (hash, parent, via, depth).
    fn sql(self) -> &'static str {
        match self {
            Walk::Up => {
                "WITH RECURSIVE up(hash, parent, via, depth) AS (
                   SELECT ?1, NULL, NULL, 0
                   UNION
                   SELECT e.to_hash, u.hash, e.role, u.depth + 1
                   FROM edges e JOIN up u ON e.from_hash = u.hash
                   WHERE e.role IN ('subject','context'))
                 SELECT * FROM up ORDER BY depth, via, hash"
            }
            Walk::Down => {
                "WITH RECURSIVE down(hash, parent, via, depth) AS (
                   SELECT ?1, NULL, NULL, 0
                   UNION
                   SELECT e.from_hash, d.hash, e.role, d.depth + 1
                   FROM edges e JOIN down d ON e.to_hash = d.hash
                   WHERE e.role IN ('subject','context'))
                 SELECT * FROM down ORDER BY depth, via, hash"
            }
        }
    }
}

fn check_supersede_cycle(conn: &Connection, new: &str, old: &str) -> Result<()> {
    let cyc = conn
        .query_row(
            "WITH RECURSIVE chain(hash) AS (
               SELECT ?1 UNION
               SELECT e.to_hash FROM edges e JOIN chain c ON e.from_hash = c.hash
               WHERE e.role = 'supersedes')
             SELECT 1 FROM chain WHERE hash = ?2",
            params![old, new],
            |_| Ok(()),
        )
        .optional()?;
    if cyc.is_some() {
        bail!("{old} already (transitively) supersedes {new}");
    }
    Ok(())
}

fn is_current(conn: &Connection, h: &str) -> Result<bool> {
    Ok(conn
        .query_row(
            "SELECT 1 FROM edges WHERE to_hash=? AND role='supersedes'",
            [h],
            |_| Ok(()),
        )
        .optional()?
        .is_none())
}

fn brief(conn: &Connection, h: &str) -> Result<Map<String, Value>> {
    let (kind, spec, status): (String, String, String) = conn.query_row(
        "SELECT kind, spec, status FROM artifacts WHERE hash=?",
        [h],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let spec: Value = serde_json::from_str(&spec)?;
    let mut m = Map::new();
    m.insert("kind".into(), json!(kind));
    m.insert("type".into(), spec["type"].clone());
    m.insert("repeatability".into(), spec["repeatability"].clone());
    m.insert("status".into(), json!(status));
    m.insert("current".into(), json!(is_current(conn, h)?));
    Ok(m)
}

fn edge_list(conn: &Connection, sql: &str, h: &str) -> Result<Value> {
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([h], |r| {
        Ok(json!({"hash": r.get::<_, String>(0)?, "role": r.get::<_, String>(1)?}))
    })?;
    Ok(Value::Array(rows.collect::<rusqlite::Result<_>>()?))
}

// --- CLI ---------------------------------------------------------------------

#[derive(Parser)]
#[command(name = "ce", about = "Context engine with source criticism (SPEC.md)")]
struct Cli {
    /// Database path; blobs/ sits next to it.
    #[arg(long, global = true, env = "CE_DB", default_value = "ce.db")]
    db: PathBuf,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create the database and blobs/ from schema.sql.
    Init,
    /// Store a source: FILE (text → payload, binary → blob), --stdin or --ref.
    Ingest {
        file: Option<PathBuf>,
        #[arg(long)]
        stdin: bool,
        /// Content-less source: a pointer or a failed retrieval.
        #[arg(long = "ref")]
        reference: bool,
        #[arg(long)]
        spec: String,
        #[arg(long, value_parser = STATUSES)]
        status: Option<String>,
        /// Force FILE into a blob even if it decodes as text.
        #[arg(long)]
        binary: bool,
    },
    /// Store a synthesis; payload on stdin.
    Synth {
        #[arg(long)]
        spec: String,
        #[arg(long, num_args = 1..)]
        subject: Vec<String>,
        #[arg(long, num_args = 1..)]
        context: Vec<String>,
        #[arg(long)]
        supersedes: Option<String>,
    },
    /// Add a supersedes edge: NEW replaces OLD.
    Supersede { new: String, old: String },
    /// Row, edges in both directions, blob path and footnote chain.
    Show { hash: String },
    /// Upstream walk: what HASH rests on.
    Up { hash: String },
    /// Downstream walk: everything built on HASH.
    Down { hash: String },
    /// Full-text search over current artifacts.
    Search { query: String },
    /// Current syntheses whose subject has been superseded.
    Stale,
}

fn parse_spec(raw: &str) -> Result<Value> {
    let spec: Value =
        serde_json::from_str(raw).map_err(|e| format!("--spec is not valid JSON: {e}"))?;
    let Some(obj) = spec.as_object() else {
        bail!("--spec must be a JSON object");
    };
    if !matches!(obj.get("type"), Some(Value::String(t)) if !t.is_empty()) {
        bail!("--spec needs a non-empty string 'type' (§2.2)");
    }
    if !matches!(obj.get("repeatability"), Some(Value::String(r)) if REPEATABILITY.contains(&r.as_str()))
    {
        bail!(
            "--spec needs 'repeatability', one of {} (§2.2)",
            REPEATABILITY.join(", ")
        );
    }
    Ok(spec)
}

fn looks_binary(data: &[u8]) -> bool {
    data.contains(&0) || std::str::from_utf8(data).is_err()
}

fn read_stdin() -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    io::stdin().read_to_end(&mut buf)?;
    Ok(buf)
}

fn emit(v: &Value) {
    // A closed pipe (`ce up … | head`) is not an error.
    if writeln!(io::stdout().lock(), "{v}").is_err() {
        std::process::exit(0);
    }
}

fn run(cli: Cli) -> Result<()> {
    let store = Store::new(&cli.db)?;
    match cli.cmd {
        Cmd::Init => emit(&store.init()?),
        Cmd::Ingest {
            file,
            stdin,
            reference,
            spec,
            status,
            binary,
        } => {
            if [file.is_some(), stdin, reference]
                .iter()
                .filter(|&&b| b)
                .count()
                != 1
            {
                bail!("ingest takes exactly one of FILE, --stdin, --ref");
            }
            let mut spec = parse_spec(&spec)?;
            let status = status.as_deref();
            if reference {
                emit(&store.ingest_ref(&spec, status.unwrap_or("ok"))?);
                return Ok(());
            }
            let data = match &file {
                Some(path) => {
                    let data = fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
                    if let Some(name) = path.file_name() {
                        spec.as_object_mut()
                            .unwrap()
                            .entry("original_name")
                            .or_insert(json!(name.to_string_lossy()));
                    }
                    data
                }
                None => {
                    let data = read_stdin()?;
                    if looks_binary(&data) {
                        bail!("--stdin takes UTF-8 text; ingest binaries as FILE");
                    }
                    data
                }
            };
            let out = if data.is_empty() {
                // No content: hash spec||created_at so empty retrievals don't collide.
                store.ingest_ref(&spec, status.unwrap_or("empty"))?
            } else if binary || looks_binary(&data) {
                store.ingest_blob(&spec, &data, status.unwrap_or("ok"))?
            } else {
                let text = String::from_utf8(data).expect("checked utf-8");
                store.ingest_text(&spec, &text, status.unwrap_or("ok"))?
            };
            emit(&out);
        }
        Cmd::Synth {
            spec,
            subject,
            context,
            supersedes,
        } => {
            let spec = parse_spec(&spec)?;
            let data = read_stdin()?;
            if data.is_empty() || looks_binary(&data) {
                bail!("synth reads its payload as non-empty UTF-8 text on stdin");
            }
            let text = String::from_utf8(data).expect("checked utf-8");
            emit(&store.synth(&spec, &text, &subject, &context, supersedes.as_deref())?);
        }
        Cmd::Supersede { new, old } => emit(&store.supersede(&new, &old)?),
        Cmd::Show { hash } => emit(&store.show(&hash)?),
        Cmd::Up { hash } => walk_cmd(&store, Walk::Up, &hash)?,
        Cmd::Down { hash } => walk_cmd(&store, Walk::Down, &hash)?,
        Cmd::Search { query } => store.search(&query)?.iter().for_each(emit),
        Cmd::Stale => store.stale()?.iter().for_each(emit),
    }
    Ok(())
}

fn walk_cmd(store: &Store, dir: Walk, hash: &str) -> Result<()> {
    let conn = store.connect()?;
    let h = store.resolve(&conn, hash)?;
    store.walk(&conn, dir, &h)?.iter().for_each(emit);
    Ok(())
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("ce: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_formatting_matches_python_strftime() {
        assert_eq!(format_utc(0, 0), "1970-01-01T00:00:00.000000Z");
        assert_eq!(format_utc(951_782_400, 0), "2000-02-29T00:00:00.000000Z");
        assert_eq!(
            format_utc(1_790_000_000, 123_456),
            "2026-09-21T14:13:20.123456Z"
        );
    }

    #[test]
    fn canonical_json_sorts_keys_compactly() {
        let v: Value = serde_json::from_str(r#"{ "b": 1, "a": {"d": "é", "c": [1, 2]} }"#).unwrap();
        assert_eq!(canonical_json(&v), r#"{"a":{"c":[1,2],"d":"é"},"b":1}"#);
    }
}
