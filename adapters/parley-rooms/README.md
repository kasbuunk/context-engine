# parley-rooms adapter

Feeds [parley](https://github.com/kasbuunk/parley) chat rooms into a `ce`
store. parley keeps one folder per Matrix room with a `room.toml` (the room's
`name`) and a `transcript.jsonl` of every message and reply. One source
artifact per room per UTC day; its payload is that day's messages, oldest
first, with thread replies marked. The spec points at the transcript. Today's
artifact grows and supersedes its previous version; a re-run with nothing new
adds nothing.

```sh
CE_DB=store.db ce-parley-rooms --skip 'work' --rooms ~/.local/share/parley/rooms
```

Python stdlib only; calls `ce`. `./test.sh` checks skips, growth and
idempotence on fake rooms.
