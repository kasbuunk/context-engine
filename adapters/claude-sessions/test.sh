#!/usr/bin/env bash
# Fake Claude Code transcripts and a fake claude.ai export through the adapter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
sid=11111111-2222-3333-4444-555555555555
mkdir -p "$tmp/live/proj" "$tmp/live/proj/$sid/subagents" "$tmp/raw" "$tmp/live/work-secret"
line() { printf '{"type":"%s","timestamp":"2026-10-25T10:0%s:00Z","cwd":"/home/k/proj","message":{"role":"%s","content":%s}}\n' "$1" "$2" "$1" "$3"; }
{ line user 1 '"how do herons hunt? <system-reminder>noise</system-reminder>"'
  line assistant 2 '[{"type":"text","text":"They wait in ditches."},{"type":"tool_use","name":"Bash","input":{"command":"grep heron notes"}}]'
  line user 3 '[{"type":"tool_result","content":"TOOL OUTPUT SHOULD NOT APPEAR"}]'
  printf '{"type":"summary","summary":"Herons"}\n'; } > "$tmp/live/proj/$sid.jsonl"
head -1 "$tmp/live/proj/$sid.jsonl" > "$tmp/raw/proj--$sid.jsonl"          # smaller copy: loses
line user 1 '"sub-agent chatter"' > "$tmp/live/proj/$sid/subagents/agent-a.jsonl"
line user 1 '"secret work"' > "$tmp/live/work-secret/99999999-2222-3333-4444-555555555555.jsonl"
cat > "$tmp/conv.json" <<'J'
[{"uuid":"aaaaaaaa-0000-0000-0000-000000000000","name":"Owls","summary":"","created_at":"2026-09-01T10:00:00Z","updated_at":"2026-09-01T11:00:00Z","chat_messages":[
 {"sender":"human","created_at":"2026-09-01T10:00:00Z","text":"","content":[{"type":"text","text":"do owls blink?"}],"attachments":[],"files":[]},
 {"sender":"assistant","created_at":"2026-09-01T10:00:05Z","text":"","content":[{"type":"text","text":"They have a third eyelid."}],"attachments":[],"files":[]}]},
 {"uuid":"bbbbbbbb-0000-0000-0000-000000000000","name":"","summary":"","created_at":"2026-09-01T10:00:00Z","updated_at":"2026-09-01T10:00:00Z","chat_messages":[]}]
J
run() { "$here/ce-claude-sessions" --skip 'work-secret' --claude-code "$tmp/live" --claude-code "$tmp/raw" --claude-ai "$tmp/conv.json"; }
out=$(run); echo "$out"
python3 - "$out" <<'PY'
import json,sys; s=json.loads(sys.argv[1])
assert s["claude_code_sessions"]==1 and s["new"]==2 and s["empty"]==1 and s["failed"]==0, s
PY
"$CE" search ditches | grep -q claude-code-session
! "$CE" search '"TOOL OUTPUT"' | grep -q . || { echo "tool result leaked"; exit 1; }
! "$CE" search noise | grep -q . || { echo "system reminder leaked"; exit 1; }
! "$CE" search chatter | grep -q . || { echo "sub-agent ingested"; exit 1; }
! "$CE" search secret | grep -q . || { echo "skipped project ingested"; exit 1; }
"$CE" search third | grep -q claude-ai-conversation

# Re-run: nothing new.
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["new"]==0 and s["updated"]==0 and s["unchanged"]==2, s' "$out"

# The session grows: stored again, superseding the old version.
line assistant 4 '[{"type":"text","text":"Also in shallow ponds."}]' >> "$tmp/live/proj/$sid.jsonl"
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["updated"]==1 and s["unchanged"]==1, s' "$out"
n=$("$CE" search ditches | wc -l); [ "$n" = 1 ] || { echo "old version still current ($n)"; exit 1; }
"$CE" search ponds | grep -q claude-code-session
echo "ok: ce-claude-sessions"
