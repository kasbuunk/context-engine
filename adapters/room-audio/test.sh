#!/usr/bin/env bash
# Fake transcriber sidecars through the adapter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
d=$tmp/a/mic1/2026/10/25; mkdir -p "$d" "$tmp/a/mic1/2026/10/26"
seg() { printf '{"s":%s,"e":%s,"text":"%s","speaker":%s}' "$1" "$2" "$3" "$4"; }
side() { printf '{"version":"v1","camera":"mic1","start":"%s","segments":[%s]}' "$1" "$2"; }
side 2026-10-25T18:00:00+02:00 "$(seg 1 3 'herons nest in colonies' '"Ann"'),$(seg 5 8 'called heronries' '"Ann"'),$(seg 60 62 'breaking news tonight' null),$(seg 70 72 'grandad here' '"Bob"')" > "$d/1800.v1.json"
side 2026-10-25T18:30:00+02:00 '' > "$d/1830.v1.json"
side 2026-10-26T07:00:00+01:00 "$(seg 1 2 'only the radio' null)" > "$tmp/a/mic1/2026/10/26/0700.v1.json"
echo '{"version":"v0","camera":"mic1","start":"2026-10-25T19:00:00+02:00","segments":[{"s":1,"e":2,"text":"old model owls","speaker":"Ann"}]}' > "$d/1900.v0.json"
run() { "$here/ce-room-audio" --archive "$tmp/a" --version v1 --people Ann,Cat --label kitchen; }
out=$(run); echo "$out"
python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s=={"days":1,"new":1,"updated":0,"unchanged":0,"empty":1,"failed":0}, s' "$out"
"$CE" search heronries | grep -q room-audio-day
for w in breaking grandad owls radio; do
  ! "$CE" search "$w" | grep -q . || { echo "left-out speech ingested: $w"; exit 1; }
done
# Re-run: nothing new.
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["new"]==0 and s["unchanged"]==1, s' "$out"
# The day grows: supersedes.
side 2026-10-25T20:00:00+02:00 "$(seg 1 3 'egrets too' '"Cat"')" > "$d/2000.v1.json"
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["updated"]==1, s' "$out"
n=$("$CE" search heronries | wc -l); [ "$n" = 1 ] || { echo "old version still current ($n)"; exit 1; }
echo "ok: ce-room-audio"
