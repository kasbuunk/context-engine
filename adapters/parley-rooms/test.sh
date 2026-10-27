#!/usr/bin/env bash
# Fake parley room folders through the adapter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
r=$tmp/rooms
mkdir -p "$r/!aaa:x" "$r/!bbb:x" "$r/!empty:x" "$r/!work:x"
echo 'name = "herons"' > "$r/!aaa:x/room.toml"
echo 'name = "secretwork"' > "$r/!work:x/room.toml"
msg() { printf '{"ts":%s,"sender":"%s","thread":%s,"body":"%s"}\n' "$1" "$2" "$3" "$4"; }
# 2026-10-25 and 2026-10-26 (UTC)
{ msg 1792900000 '@kas:chat.x' null 'where do herons nest?'
  msg 1792900010 agent '"$t1"' 'In colonies called heronries.'
  msg 1792990000 '@kas:chat.x' null 'and egrets?'
  echo 'not json'; } > "$r/!aaa:x/transcript.jsonl"
msg 1792900000 '@kas:chat.x' null 'owls blink sideways' > "$r/!bbb:x/transcript.jsonl"
msg 1792900000 '@kas:chat.x' null 'confidential roadmap' > "$r/!work:x/transcript.jsonl"
run() { "$here/ce-parley-rooms" --skip secretwork --rooms "$r"; }
out=$(run); echo "$out"
python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s=={"rooms":2,"new":3,"updated":0,"unchanged":0,"failed":0}, s' "$out"
"$CE" search heronries | grep -q parley-room-day
! "$CE" search confidential | grep -q . || { echo "skipped room ingested"; exit 1; }

# Re-run: nothing new.
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["new"]==0 and s["updated"]==0 and s["unchanged"]==3, s' "$out"

# The day grows: stored again, superseding the old version.
msg 1792990100 agent null 'Egrets nest with them.' >> "$r/!aaa:x/transcript.jsonl"
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["updated"]==1 and s["unchanged"]==2, s' "$out"
n=$("$CE" search egrets | wc -l); [ "$n" = 1 ] || { echo "old version still current ($n)"; exit 1; }
echo "ok: ce-parley-rooms"
