# Context Engine with Source Criticism

See `SPEC.md`. Reference implementation: `ce`, a single-binary Rust CLI over
`schema.sql` (compiled in), linked against the system SQLite (3.40 in the
dev container).

```sh
cargo build --release           # → target/release/ce
ce init --db ce.db              # or export CE_DB=...; blobs/ sits next to the db
echo hi | ce ingest --stdin --spec '{"type":"manual-export","repeatability":"manual"}'
ce show <hash-or-prefix>
cargo test
```
