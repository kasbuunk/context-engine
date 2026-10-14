#!/usr/bin/env bash
# End-to-end check on a throwaway repo: versions supersede, links become
# subject edges, a link made before the target was committed is flagged
# stale once it is, and a re-run adds nothing.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
export CE=${CE:-$here/../../target/release/ce}
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
export CE_DB=$t/ce.db
r=$t/repo; mkdir -p "$r/src" "$r/notes" "$r/src/sub"; cd "$r"
git init -q; git config user.email t@t; git config user.name t; git config commit.gpgsign false
c() { git add -A; git commit -qm "$1"; }
fail() { echo "FAIL: $*"; exit 1; }

# 1. a note cites a source that is not committed yet
printf -- '---\nsource: "[[a]]"\n---\nnote v1\n' > notes/n.md; c n1
# 2. the source arrives, citing a file kept outside git
printf -- '---\nraw: blobs/a.wav\n---\nsource a v1\n' > src/a.md;  c a1
# 3. the note is rewritten against the source as it now stands
printf -- '---\nsource: "[[a]]"\n---\nnote v2\n' > notes/n.md; c n2
# non-ASCII name, a path relative to an ancestor dir, and a rewritten alias
printf -- '---\nsource: src/a.md\nraw: $STORE/blobs/a.wav\n---\nnote \xe2\x80\x94 ascii-free\n' > "notes/n — b.md"
printf -- '---\nsource: sub/c.md\n---\nd\n' > src/sub/d.md; printf 'c\n' > src/sub/c.md
printf -- '---\nsource: src/x, y.md\n---\ne\n' > src/e.md; printf 'x\n' > "src/x, y.md"
c extra
# 4. the source is redone
printf -- '---\nraw: blobs/a.wav\n---\nsource a v2\n' > src/a.md;  c a2

"$CE" init >/dev/null
run() { "$here/ce-git-history" --repo "$r" --name demo --link-key source --link-key raw --rewrite '$STORE/=' -- 'notes/*' 'src/*'; }
first=$(run); echo "first run:  $first"
rows() { sqlite3 "$CE_DB" "select (select count(*) from artifacts)||'/'||(select count(*) from edges)"; }
before=$(rows)
second=$(run); echo "second run: $second"
[ "$(rows)" = "$before" ] || fail "re-run changed the store ($before -> $(rows))"

q() { sqlite3 "$CE_DB" "$1"; }
[ "$(q "select count(*) from artifacts where json_extract(spec,'\$.type')='git-file'")" = 9 ] || fail "want 9 versions"
[ "$(q "select count(*) from artifacts where json_extract(spec,'\$.type')='git-file-uncommitted' and status='failed'")" = 1 ] || fail "want 1 stand-in"
[ "$(q "select count(*) from artifacts where json_extract(spec,'\$.type')='external-file'")" = 1 ] || fail "want 1 external ref"
stale=$("$CE" stale); echo "$stale"
[ "$(printf '%s\n' "$stale" | grep -c .)" = 2 ] || fail "want two stale syntheses: both notes cite source a v1"
note_v2=$(q "select hash from artifacts where payload like '%note v2%'")
printf '%s' "$stale" | grep -q "$note_v2" || fail "stale row is not note v2"
[ "$(q "select count(*) from edges e join artifacts t on t.hash=e.to_hash where e.role='subject' and json_extract(t.spec,'\$.path')='src/sub/c.md'")" = 1 ] || fail "suffix-relative link did not resolve"
q "select json_extract(spec,'\$.path') from artifacts" | grep -q '^notes/n — b.md$' || fail "non-ASCII path not ingested"
echo PASS
