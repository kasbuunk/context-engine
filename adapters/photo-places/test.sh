#!/usr/bin/env bash
# A fake visits/trips database through the adapter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
python3 - "$tmp/l.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE meta (key TEXT, value TEXT);
INSERT INTO meta VALUES ('home_place', 'Hometown'), ('places_built_at', 'x');
CREATE TABLE visits (ts_start REAL, photo_count INTEGER, place TEXT, town TEXT, admin1 TEXT, admin2 TEXT,
  country_name TEXT, km_from_home REAL);
CREATE TABLE trips (trip_id INTEGER, ts_start REAL, ts_end REAL, days INTEGER, countries TEXT, places TEXT,
  max_km_from_home REAL);
INSERT INTO visits VALUES (1790000000, 3, 'Home St', 'Hometown', NULL, NULL, 'Netherlands', 0.5),
  (1792000000, 9, 'Vouvant', 'Fontenay-le-Comte', 'Pays de la Loire', 'Vendée', 'France', 765);
INSERT INTO trips VALUES (1, 1791900000, 1792100000, 3, 'France', 'Vouvant', 765);
""")
c.commit()
PY
run() { "$here/ce-photo-places" --db "$tmp/l.db"; }
out=$(run); echo "$out"
python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["new"]==2, s' "$out"
"$CE" search Vouvant | grep -q photo-places-month || { echo "visit missing"; exit 1; }
"$CE" search '"absence of evidence" OR "not evidence of absence"' | grep -q . || { echo "lower-bound caveat missing"; exit 1; }
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["unchanged"]==2, s' "$out"
echo "ok: ce-photo-places"
