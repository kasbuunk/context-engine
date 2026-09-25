"""M0 tests: the §4 invariants, exercised through the CLI (SPEC.md §6)."""

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest

CE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ce")

SRC = {"type": "manual-export", "repeatability": "manual"}
LLM = {"type": "llm", "repeatability": "volatile", "model": "test-model",
       "prompt_hash": "0" * 64, "tool": "test", "tool_version": "0"}


class CETest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.db = os.path.join(self.dir, "ce.db")
        self.ce("init")

    def tearDown(self):
        self.tmp.cleanup()

    def run_ce(self, *args, stdin=None):
        return subprocess.run([sys.executable, CE, "--db", self.db, *args],
                              input=stdin, capture_output=True)

    def ce(self, *args, stdin=None):
        """Run ce, assert success, return the parsed JSON lines."""
        if isinstance(stdin, str):
            stdin = stdin.encode("utf-8")
        r = self.run_ce(*args, stdin=stdin)
        self.assertEqual(r.returncode, 0, r.stderr.decode())
        return [json.loads(l) for l in r.stdout.decode().splitlines() if l]

    def one(self, *args, **kw):
        out = self.ce(*args, **kw)
        self.assertEqual(len(out), 1, out)
        return out[0]

    def text(self, body, spec=SRC):
        return self.one("ingest", "--stdin", "--spec", json.dumps(spec),
                        stdin=body)["hash"]

    def synth(self, body, subjects, contexts=(), supersedes=None):
        args = ["synth", "--spec", json.dumps(LLM), "--subject", *subjects]
        if contexts:
            args += ["--context", *contexts]
        if supersedes:
            args += ["--supersedes", supersedes]
        return self.one(*args, stdin=body)["hash"]

    def sql(self, q, *params):
        conn = sqlite3.connect(self.db)
        try:
            return conn.execute(q, params).fetchall()
        finally:
            conn.close()

    def count(self, table):
        return self.sql(f"SELECT count(*) FROM {table}")[0][0]


class TestImmutability(CETest):
    def test_update_and_delete_fail(self):
        a = self.text("alpha")
        b = self.synth("about alpha", [a])
        conn = sqlite3.connect(self.db)
        for stmt in ("UPDATE artifacts SET status='failed'",
                     "DELETE FROM artifacts",
                     "UPDATE edges SET role='context'",
                     "DELETE FROM edges"):
            with self.subTest(stmt=stmt):
                with self.assertRaisesRegex(sqlite3.IntegrityError, "immutable"):
                    conn.execute(stmt)
        conn.close()
        self.assertEqual(self.count("artifacts"), 2)
        self.assertEqual(self.sql("SELECT from_hash, to_hash, role FROM edges"),
                         [(b, a, "subject")])


class TestHashing(CETest):
    def test_reingest_identical_content_is_noop(self):
        first = self.one("ingest", "--stdin", "--spec", json.dumps(SRC),
                         stdin="same bytes\n")
        path = os.path.join(self.dir, "renamed.md")
        with open(path, "w") as f:
            f.write("same bytes\n")
        again = self.one("ingest", path, "--spec",
                         json.dumps({"type": "git-file", "repeatability": "stable"}))
        self.assertTrue(first["created"])
        self.assertFalse(again["created"])
        self.assertEqual(first["hash"], again["hash"])
        self.assertEqual(first["hash"], hashlib.sha256(b"same bytes\n").hexdigest())
        self.assertEqual(self.count("artifacts"), 1)

    def test_failed_retrieval_is_stored_and_distinct_from_retry(self):
        spec = {"type": "grafana-query", "repeatability": "decaying",
                "query": "rate(errors[5m])", "token_ref": "env:GRAFANA_TOKEN"}
        h1 = self.one("ingest", "--ref", "--spec", json.dumps(spec),
                      "--status", "failed")["hash"]
        h2 = self.one("ingest", "--ref", "--spec", json.dumps(spec),
                      "--status", "failed")["hash"]
        self.assertNotEqual(h1, h2)
        rows = self.sql("SELECT hash, spec, created_at, status, payload "
                        "FROM artifacts ORDER BY created_at")
        self.assertEqual(len(rows), 2)
        for h, spec_json, created_at, status, payload in rows:
            self.assertEqual(status, "failed")
            self.assertIsNone(payload)
            # Invariant 2: recomputable as canonical_json(spec) || created_at.
            canon = json.dumps(json.loads(spec_json), sort_keys=True,
                               separators=(",", ":"), ensure_ascii=False)
            self.assertEqual(spec_json, canon)
            self.assertEqual(
                h, hashlib.sha256((canon + created_at).encode()).hexdigest())

    def test_empty_stdin_is_stored_as_empty_not_collapsed(self):
        h1 = self.one("ingest", "--stdin", "--spec", json.dumps(SRC), stdin="")
        h2 = self.one("ingest", "--stdin", "--spec", json.dumps(SRC), stdin="")
        self.assertNotEqual(h1["hash"], h2["hash"])
        self.assertEqual(self.sql("SELECT DISTINCT status FROM artifacts"),
                         [("empty",)])

    def test_every_text_hash_is_recomputable(self):
        a = self.text("héllo wörld\r\nline two")
        self.synth("claim ✓", [a])
        for h, payload in self.sql("SELECT hash, payload FROM artifacts"):
            self.assertEqual(h, hashlib.sha256(payload.encode()).hexdigest())


class TestBlobs(CETest):
    def test_binary_lands_at_fanout_path_and_matches_shasum(self):
        data = bytes(range(256)) * 64
        path = os.path.join(self.dir, "recording.wav")
        with open(path, "wb") as f:
            f.write(data)
        out = self.one("ingest", path, "--spec", json.dumps(SRC))
        h = out["hash"]
        shasum = subprocess.run(["shasum", "-a", "256", path],
                                capture_output=True, text=True, check=True)
        self.assertEqual(h, shasum.stdout.split()[0])
        fanout = os.path.join(self.dir, "blobs", h[:2], h[2:])
        self.assertEqual(out["blob"], fanout)
        with open(fanout, "rb") as f:
            self.assertEqual(f.read(), data)
        # No leftover temp files from the atomic write.
        self.assertEqual(os.listdir(os.path.dirname(fanout)), [h[2:]])
        (payload, blob_path, spec), = self.sql(
            "SELECT payload, blob_path, spec FROM artifacts WHERE hash=?", h)
        self.assertIsNone(payload)
        self.assertIsNone(blob_path)  # derivable from the hash
        self.assertEqual(json.loads(spec)["original_name"], "recording.wav")

    def test_text_file_has_no_blob(self):
        path = os.path.join(self.dir, "notes.vtt")
        with open(path, "w") as f:
            f.write("WEBVTT\n\n00:00.000 --> 00:01.000\nhello\n")
        h = self.one("ingest", path, "--spec", json.dumps(SRC))["hash"]
        self.assertFalse(os.path.exists(os.path.join(self.dir, "blobs", h[:2])))
        self.assertEqual(len(self.ce("search", "hello")), 1)


class TestSynthesis(CETest):
    def test_synthesis_without_subject_is_rejected(self):
        r = self.run_ce("synth", "--spec", json.dumps(LLM), stdin=b"orphan claim")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(b"subject", r.stderr)
        self.assertEqual(self.count("artifacts"), 0)

    def test_synthesis_is_atomic_with_its_edges(self):
        a = self.text("real source")
        r = self.run_ce("synth", "--spec", json.dumps(LLM),
                        "--subject", a, "--context", "f" * 64,
                        stdin=b"claim with a bad footnote")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.count("artifacts"), 1)
        self.assertEqual(self.count("edges"), 0)

    def test_spec_requires_type_and_repeatability(self):
        for spec in ({}, {"type": "x"}, {"type": "x", "repeatability": "maybe"}):
            r = self.run_ce("ingest", "--stdin", "--spec", json.dumps(spec),
                            stdin=b"x")
            self.assertNotEqual(r.returncode, 0, spec)
        self.assertEqual(self.count("artifacts"), 0)


class TestStaleness(CETest):
    def test_stale_flags_synthesis_after_subject_superseded(self):
        v1 = self.text("ticket v1")
        s = self.synth("summary of ticket", [v1])
        self.assertEqual(self.ce("stale"), [])
        v2 = self.text("ticket v2")
        self.one("supersede", v2, v1)
        self.assertEqual(self.ce("stale"),
                         [{"synthesis": s, "superseded_subject": v1}])
        # Rebuilding the synthesis on v2 and superseding the old one clears it.
        self.synth("summary of ticket v2", [v2], supersedes=s)
        self.assertEqual(self.ce("stale"), [])

    def test_context_supersession_is_not_stale(self):
        subj, ctx = self.text("subject"), self.text("glossary v1")
        self.synth("claim", [subj], contexts=[ctx])
        self.one("supersede", self.text("glossary v2"), ctx)
        self.assertEqual(self.ce("stale"), [])

    def test_supersede_cycle_rejected(self):
        a, b = self.text("a"), self.text("b")
        self.one("supersede", b, a)
        self.assertNotEqual(self.run_ce("supersede", a, b).returncode, 0)

    def test_search_returns_current_only(self):
        v1 = self.text("the quarterly budget draft")
        self.assertEqual(len(self.ce("search", "budget")), 1)
        v2 = self.text("the quarterly budget final")
        self.one("supersede", v2, v1)
        hits = self.ce("search", "budget")
        self.assertEqual([h["hash"] for h in hits], [v2])


class TestWalks(CETest):
    def setUp(self):
        super().setUp()
        self.rec = self.one("ingest", "--ref", "--spec", json.dumps(
            {"type": "teams-recording", "repeatability": "manual"}))["hash"]
        self.transcript = self.synth("we chose sqlite because", [self.rec])
        self.gloss = self.text("glossary: ADR = architecture decision record")
        self.fact = self.synth("fact: sqlite chosen", [self.transcript],
                               contexts=[self.gloss])
        self.adr = self.synth("ADR-1: use sqlite", [self.fact])

    def test_show_prints_full_footnote_chain(self):
        d = self.one("show", self.adr)
        self.assertEqual(d["kind"], "synthesis")
        self.assertEqual(d["edges_out"], [{"hash": self.fact, "role": "subject"}])
        chain = {(f["hash"], f["parent"], f["via"], f["depth"])
                 for f in d["footnotes"]}
        self.assertEqual(chain, {
            (self.fact, self.adr, "subject", 1),
            (self.transcript, self.fact, "subject", 2),
            (self.gloss, self.fact, "context", 2),
            (self.rec, self.transcript, "subject", 3),
        })
        self.assertEqual(self.one("show", self.rec)["edges_in"],
                         [{"hash": self.transcript, "role": "subject"}])

    def test_up_reaches_primary_source(self):
        up = self.ce("up", self.adr[:8])
        self.assertEqual(up[-1]["hash"], self.rec)
        self.assertEqual(up[-1]["kind"], "source")

    def test_down_is_contamination_trace(self):
        down = {r["hash"]: r["via"] for r in self.ce("down", self.gloss)}
        self.assertEqual(down, {self.gloss: None, self.fact: "context",
                                self.adr: "subject"})


if __name__ == "__main__":
    unittest.main()
