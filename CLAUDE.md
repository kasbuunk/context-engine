# context-engine

`SPEC.md` describes the model, schema, invariants and CLI surface. Read it
before writing code. It is a starting point, not a contract.

## Change it as we use it (Kas, 2026-10-25)

The engine is in daily use: agents on the home lab query it over MCP
(`adapters/mcp/`) and save syntheses into it. Whenever using it shows that
something should be different and more useful another way, change it:
columns, enum values, edge roles, structure, the CLI, the adapters, even the
database engine. Judge a change by utility in real use, not by elegance.
The milestone order in SPEC §6 and its "out of scope until M2" list no longer
gate anything.

How:

- Say what in actual use prompted the change (a query that failed, an edge
  that had no fitting role, a search that missed), in the commit message, and
  update SPEC.md in the same commit so it keeps describing what the code does.
- **Never lose data in a store.** Sources and their versions can be rebuilt by
  re-running the ingest adapters, but syntheses saved by agents (`type: llm`)
  cannot. A schema change ships with a migration of existing stores. Before
  migrating the lab store, back it up (`sqlite3 .backup`, or Python's
  `sqlite3` backup API since the lab has no sqlite3 CLI).
- Keep tests passing (`cargo test`, `adapters/*/test.sh`); `nix build` runs
  them.
- Adapters stay removable: they call `ce`, never the other way round.
- No private data in this repo; it is public. Private config (which files to
  feed) lives in Kas's vault, `ai/ce/`.

## Where it runs

- Lab (writer): clone `~/git/github.com/kasbuunk/context-engine` (read-write
  deploy key), build with `nix build -o ~/.config/ce/current`, store at
  `~/.local/share/ce/personal/ce.db`, snapshot to `$LAKE/ce/personal/`.
  `ce-ingest.timer` (NixOS, `modules/ce-ingest.nix`) feeds it hourly.
- MCP: registered at user scope on the lab, and on Kas's Mac over
  `ssh homelab-agent`. A new build is live for the next MCP session; no
  restart of anything else is needed.
- Development elsewhere can use the `mage context-engine` container (see
  `.mage/`).
