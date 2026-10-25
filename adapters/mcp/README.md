# mcp adapter

A read-only [MCP](https://modelcontextprotocol.io) server over the `ce` verbs,
so an agent can query a store: `search`, `show`, `up`, `down`, `stale`. It runs
`ce` against `$CE_DB` and never writes. Python stdlib only, stdio transport.
Delete this directory and nothing else breaks.

```sh
claude mcp add -s user ce -e CE_DB=/path/ce.db -e CE=/path/ce -- /path/adapters/mcp/ce-mcp
```

`./test.sh` builds a throwaway store and checks the protocol round trip.
