#!/usr/bin/env bash
# Builds a throwaway store, talks MCP to ce-mcp over stdio, checks the answers.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
src=$(echo "the heron stood in the ditch" | "$CE" ingest --stdin --spec '{"type":"manual-export","repeatability":"manual"}' | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["hash"])')
syn=$(echo "summary: a heron" | "$CE" synth --spec '{"type":"summary","repeatability":"volatile"}' --subject "$src" | python3 -c 'import json,sys;print(json.loads(sys.stdin.read())["hash"])')

out=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"heron"}}}' \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"up\",\"arguments\":{\"hash\":\"$syn\"}}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"show\",\"arguments\":{\"hash\":\"${src:0:12}\"}}}" \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"show","arguments":{"hash":"nope"}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"drop","arguments":{}}}' \
  | "$here/ce-mcp")

python3 - "$out" "$src" "$syn" <<'PY'
import json, sys
lines = [json.loads(l) for l in sys.argv[1].splitlines()]
src, syn = sys.argv[2], sys.argv[3]
by = {m["id"]: m for m in lines}
assert len(lines) == 7, f"one reply per request, none for the notification: {len(lines)}"
assert by[1]["result"]["capabilities"] == {"tools": {}}
assert {t["name"] for t in by[2]["result"]["tools"]} == {"search", "show", "up", "down", "stale", "synth"}
hits = by[3]["result"]["content"][0]["text"]
assert src[:12] in hits and syn[:12] in hits, hits
walk = by[4]["result"]["content"][0]["text"]
assert walk.splitlines()[0].startswith(syn[:12]) and src[:12] in walk, walk
assert "heron" in by[5]["result"]["content"][0]["text"]
assert by[6]["result"]["isError"] is True
assert by[7]["error"]["code"] == -32602
print("ok: ce-mcp")
PY

# synth: an agent saves what it derived; it is searchable and walks up to its source.
rpc() { printf '%s\n' "$@" | "$here/ce-mcp"; }
text() { python3 -c 'import json,sys; m=json.loads(sys.stdin.read()); print(m["result"]["content"][0]["text"])'; }
saved=$(CE_MCP_AGENT=test rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"synth\",\"arguments\":{\"text\":\"Herons hunt in ditches.\",\"subjects\":[\"${src:0:12}\"],\"context\":[\"$syn\"],\"question\":\"where do herons hunt\"}}}" | text)
case $saved in "saved "*) ;; *) echo "synth failed: $saved"; exit 1 ;; esac
new=${saved#saved }
"$CE" show "$new" | python3 -c '
import json,sys
r=json.loads(sys.stdin.read())
assert r["kind"]=="synthesis", r
assert r["spec"]["type"]=="llm" and r["spec"]["agent"]=="test" and r["spec"]["question"]=="where do herons hunt", r["spec"]
roles=sorted(e["role"] for e in r["edges_out"]); assert roles==["context","subject"], roles
'
rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":{"query":"ditches"}}}' | text | grep -q "${new:0:12}"

# A synthesis without a subject is refused by ce and reported, not crashed on.
err=$(rpc '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"synth","arguments":{"text":"x","subjects":["ffffffff"]}}}' | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["result"]["isError"])')
[ "$err" = True ]

# Read-only: no synth tool listed, and calling it is an unknown tool.
ro=$(CE_MCP_READONLY=1 rpc '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"synth","arguments":{"text":"x","subjects":["'"$src"'"]}}}')
python3 - "$ro" <<'PY'
import json, sys
a, b = [json.loads(l) for l in sys.argv[1].splitlines()]
assert "synth" not in {t["name"] for t in a["result"]["tools"]}
assert b["error"]["code"] == -32602
print("ok: synth, read-only")
PY
