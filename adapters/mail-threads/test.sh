#!/usr/bin/env bash
# A fake mail metadata database and one .emlx through the adapter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
python3 - "$tmp" <<'PY'
import sqlite3, sys, os
d = sys.argv[1]
c = sqlite3.connect(d + "/mail.db")
c.executescript("""
CREATE TABLE addresses (rowid INTEGER PRIMARY KEY, address TEXT, comment TEXT);
CREATE TABLE recipients (rowid INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
CREATE TABLE messages (rowid INTEGER PRIMARY KEY, conversation_id INTEGER, message_id_header TEXT, subject TEXT,
  sender INTEGER, ts_sent INTEGER, ts_received INTEGER, deleted INTEGER);
INSERT INTO addresses VALUES (1,'me@example.org','Me'),(2,'ada@example.org','Ada'),(3,'noreply@shop.example','Shop');
INSERT INTO messages VALUES
 (10, 100, '<a@x>', 'Herons', 1, 1792900000, NULL, 0),
 (11, 100, '<b@x>', 'Re: Herons', 2, 1792900600, NULL, 0),
 (12, 200, '<c@x>', 'Your weekly deals', 3, 1792900000, NULL, 0);
INSERT INTO recipients VALUES (1,10,2,0,0),(2,11,1,0,0),(3,12,1,0,0);
""")
c.commit()
os.makedirs(d + "/store/INBOX.mbox/Messages")
raw = (b"Message-ID: <b@x>\nSubject: Re: Herons\nContent-Type: text/plain\n\n"
       b"They nest in heronries.\n\nOn Monday Me wrote:\n> where do herons nest?\n")
open(d + "/store/INBOX.mbox/Messages/999.emlx", "wb").write(str(len(raw)).encode() + b"\n" + raw + b"<plist/>")
PY
run() { "$here/ce-mail-threads" --db "$tmp/mail.db" --mailstore "$tmp/store" --me me@example.org; }
out=$(run); echo "$out"
python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["kept"]==1 and s["new"]==1 and s["bodies"]==1, s' "$out"
"$CE" search heronries | grep -q mail-thread || { echo "body missing"; exit 1; }
! "$CE" search deals | grep -q . || { echo "newsletter ingested"; exit 1; }
! "$CE" search '"where do herons"' | grep -q . || { echo "quoted history kept"; exit 1; }
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["unchanged"]==1 and s["new"]==0, s' "$out"
echo "ok: ce-mail-threads"
