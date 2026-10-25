# mcp adapter

An [MCP](https://modelcontextprotocol.io) server over the `ce` verbs, so an
agent can query a store (`search`, `show`, `up`, `down`, `stale`) and save
what it derived (`synth`). Saving is the only write: a synthesis with
`subject`/`context` edges to the artifacts it rests on, spec
`{type: llm, repeatability: volatile, agent, question, made_at}`. Set
`CE_MCP_READONLY=1` to leave `synth` out. Python stdlib only, stdio
transport. Delete this directory and nothing else breaks.

```sh
claude mcp add -s user ce -e CE_DB=/path/ce.db -e CE=/path/ce -e CE_MCP_AGENT=me@host \
  -- /path/adapters/mcp/ce-mcp
# a store on another host: stdio runs fine over ssh
claude mcp add -s user ce -- ssh host env CE_DB=/path/ce.db CE=/path/ce /path/ce-mcp
```

`./test.sh` builds a throwaway store and checks the protocol round trip,
`synth` edges and spec, and read-only mode.
