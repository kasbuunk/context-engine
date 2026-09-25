# Context Engine with Source Criticism

See `SPEC.md`. Reference implementation: `ce`, a single-file Python 3.11 CLI
(stdlib only) over `schema.sql`.

```sh
./ce init --db ce.db            # or export CE_DB=...; blobs/ sits next to the db
echo hi | ./ce ingest --stdin --spec '{"type":"manual-export","repeatability":"manual"}'
./ce show <hash-or-prefix>
python3 -m unittest discover -s tests -v
```
