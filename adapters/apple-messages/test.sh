#!/usr/bin/env bash
# A fake messages + contacts database through the adapter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
python3 - "$tmp" <<'PY'
import sqlite3, sys
d = sys.argv[1]
c = sqlite3.connect(d + "/m.db")
c.executescript("""
CREATE TABLE chats (guid TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT, style INTEGER);
CREATE TABLE messages (guid TEXT, text TEXT, text_decoded TEXT, handle TEXT, ts_utc REAL, is_from_me INTEGER,
  is_audio_message INTEGER, item_type INTEGER, associated_message_type INTEGER, balloon_bundle_id TEXT);
CREATE TABLE chat_message_join (chat_guid TEXT, message_guid TEXT);
CREATE TABLE attachments (guid TEXT, transfer_name TEXT, filename TEXT, mime_type TEXT);
CREATE TABLE message_attachment_join (message_guid TEXT, attachment_guid TEXT);
INSERT INTO chats VALUES ('c1', '+31600000001', 'iMessage', NULL, 45), ('c2', 'secret', 'SMS', 'Work', 43);
INSERT INTO messages VALUES
 ('m1', 'where do herons nest?', NULL, '+31600000001', 1792900000, 0, 0, 0, 0, NULL),
 ('m2', NULL, 'in heronries', NULL, 1792900060, 1, 0, 0, 0, NULL),
 ('m3', 'Loved', NULL, '+31600000001', 1792900070, 0, 0, 0, 2000, NULL),
 ('m4', 'confidential roadmap', NULL, '+31600000002', 1792900000, 0, 0, 0, 0, NULL),
 ('m5', '', NULL, '+31600000001', 1792900080, 0, 0, 0, 0, NULL);
INSERT INTO chat_message_join VALUES ('c1','m1'),('c1','m2'),('c1','m3'),('c2','m4'),('c1','m5');
INSERT INTO attachments VALUES ('a1', 'heron.jpg', NULL, 'image/jpeg');
INSERT INTO message_attachment_join VALUES ('m5', 'a1');
""")
c.commit()
k = sqlite3.connect(d + "/c.db")
k.executescript("""
CREATE TABLE contacts (uuid TEXT, display_name TEXT, first_name TEXT, last_name TEXT, nickname TEXT, organization TEXT);
CREATE TABLE phones (contact_uuid TEXT, full_number TEXT);
CREATE TABLE emails (contact_uuid TEXT, address TEXT);
INSERT INTO contacts VALUES ('u1', NULL, 'Ada', 'Heron', NULL, NULL);
INSERT INTO phones VALUES ('u1', '06 0000 0001');
""")
k.commit()
PY
run() { "$here/ce-apple-messages" --db "$tmp/m.db" --contacts "$tmp/c.db" --me Me --skip '^Work$'; }
out=$(run); echo "$out"
python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["new"]==1 and s["skipped_chats"]==1, s' "$out"
p=$("$CE" search heronries)
echo "$p" | grep -q 'Ada Heron' || { echo "contact name not resolved"; exit 1; }
! "$CE" search confidential | grep -q . || { echo "skipped chat ingested"; exit 1; }
! "$CE" search Loved | grep -q . || { echo "tapback ingested"; exit 1; }
"$CE" search '"heron.jpg"' | grep -q apple-messages-day || { echo "attachment marker missing"; exit 1; }
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["unchanged"]==1 and s["new"]==0, s' "$out"
echo "ok: ce-apple-messages"
