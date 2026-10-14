# git-history adapter

Feeds a Git repo's file history into a `ce` store. It is an adapter, not part
of the store: it only shells out to `ce` and reads the database to stay
idempotent. Python stdlib only. Delete this directory and nothing else breaks.

- Every committed version of a matched file becomes an artifact; each version
  supersedes the previous one.
- A file whose YAML frontmatter names other files under a `--link-key`
  (wikilinks or paths) becomes a **synthesis** with a `subject` edge to the
  linked file *as it stood at the same commit*. Files without links are
  **sources**.
- Link targets outside Git become `external-file` refs. A link to a file that
  had no committed version yet becomes a `git-file-uncommitted` ref with
  status `failed`, superseded by the first real version — so `ce stale` flags
  every claim built on a version nobody can retrieve any more.
- Encrypted repos (git-crypt) work: content is read with `git show --textconv`.

```sh
CE_DB=store.db ce-git-history --repo ~/notes --name notes \
  --link-key source --rewrite 'raw/=$ARCHIVE/raw/' -- 'notes/*.md' 'sources/*.md'
ce stale
```

`./test.sh` builds a throwaway repo and checks supersession, link resolution
(wikilink, relative, non-ASCII paths, rewrites), stale detection and that a
re-run changes nothing.
