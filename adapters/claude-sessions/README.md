# claude-sessions adapter

Feeds Claude conversations into a `ce` store: Claude Code transcripts
(`~/.claude/projects/**/*.jsonl`, or an archive of them) and claude.ai data
exports (`conversations.json`). One source artifact per session, whose payload
is a readable transcript (speaker, time, text, one line per tool call; tool
results, thinking and harness-injected text left out). The spec points at the
original file. A session that grew since the last run supersedes its previous
version; a re-run with nothing new adds nothing.

```sh
CE_DB=store.db ce-claude-sessions --skip 'work-project' \
  --claude-code ~/.claude/projects --claude-ai export/conversations.json
```

Python stdlib only; calls `ce`. `./test.sh` checks dedupe, skips, growth and
idempotence on fake transcripts.
