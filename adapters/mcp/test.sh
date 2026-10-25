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
assert {t["name"] for t in by[2]["result"]["tools"]} == {"search", "show", "up", "down", "stale"}
hits = by[3]["result"]["content"][0]["text"]
assert src[:12] in hits and syn[:12] in hits, hits
walk = by[4]["result"]["content"][0]["text"]
assert walk.splitlines()[0].startswith(syn[:12]) and src[:12] in walk, walk
assert "heron" in by[5]["result"]["content"][0]["text"]
assert by[6]["result"]["isError"] is True
assert by[7]["error"]["code"] == -32602
print("ok: ce-mcp")
PY
