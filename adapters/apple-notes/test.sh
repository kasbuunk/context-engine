#!/usr/bin/env bash
# A fake notes database through the adapter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
notes=$tmp/notes.db
python3 - "$notes" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE folders (pk INTEGER PRIMARY KEY, title TEXT);
CREATE TABLE notes (identifier TEXT, folder_pk INTEGER, title TEXT, body_text TEXT,
  creation_ts_utc INTEGER, modification_ts_utc INTEGER, marked_for_deletion INTEGER,
  is_password_protected INTEGER);
INSERT INTO folders VALUES (1, 'Notes');
INSERT INTO notes VALUES ('A', 1, 'Herons', 'herons nest in heronries', 1700000000, 1700000000, 0, 0);
INSERT INTO notes VALUES ('B', 1, 'Wifi', 'wachtwoord hunter2', 1700000000, 1700000000, 0, 0);
INSERT INTO notes VALUES ('C', 1, 'Empty', '', 1700000000, 1700000000, 0, 0);
INSERT INTO notes VALUES ('D', NULL, 'Locked', 'secret diary', 1700000000, 1700000000, 0, 1);
""")
c.commit()
PY
run() { "$here/ce-apple-notes" --skip-body 'wachtwoord' --db "$notes"; }
check() { python3 -c 'import json,sys; s=json.loads(sys.argv[1]); e=json.loads(sys.argv[2]); assert all(s[k]==v for k,v in e.items()), s' "$1" "$2"; }
out=$(run); echo "$out"; check "$out" '{"new":1,"skipped":1,"empty":2}'
"$CE" search heronries | grep -q apple-note
! "$CE" search hunter2 | grep -q . || { echo "skipped note ingested"; exit 1; }
! "$CE" search diary | grep -q . || { echo "locked note ingested"; exit 1; }
out=$(run); check "$out" '{"new":0,"unchanged":1}'
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE notes SET body_text=? WHERE identifier=?", ("herons and egrets nest in heronries","A")); c.commit()' "$notes"
out=$(run); check "$out" '{"updated":1}'
n=$("$CE" search heronries | wc -l); [ "$n" = 1 ] || { echo "old version still current ($n)"; exit 1; }
echo "ok: ce-apple-notes"
