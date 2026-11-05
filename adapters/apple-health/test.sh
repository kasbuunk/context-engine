#!/usr/bin/env bash
# A fake health database (two overlapping exports) through the adapter.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
export CE=${CE:-$root/target/release/ce}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CE_DB=$tmp/ce.db
"$CE" init >/dev/null
python3 - "$tmp/h.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE imports (id INTEGER PRIMARY KEY, export_date TEXT);
CREATE TABLE records (import_id INTEGER, type TEXT, value TEXT, source_name TEXT, start_date TEXT, end_date TEXT);
CREATE TABLE workouts (import_id INTEGER, activity_type TEXT, duration REAL, duration_unit TEXT,
  total_distance REAL, total_distance_unit TEXT, start_date TEXT);
INSERT INTO imports VALUES (1, '2026-04-01 10:00:00 +0200'), (2, '2026-10-01 10:00:00 +0200');
""")
for imp in (1, 2):
    c.executemany("INSERT INTO records VALUES (?,?,?,?,?,?)", [
        (imp, 'HKQuantityTypeIdentifierStepCount', '3000', 'phone', '2026-03-02 09:00:00 +0100', '2026-03-02 10:00:00 +0100'),
        (imp, 'HKQuantityTypeIdentifierStepCount', '1000', 'phone', '2026-03-02 11:00:00 +0100', '2026-03-02 12:00:00 +0100'),
        (imp, 'HKQuantityTypeIdentifierStepCount', '3500', 'watch', '2026-03-02 09:00:00 +0100', '2026-03-02 12:00:00 +0100'),
        (imp, 'HKQuantityTypeIdentifierRestingHeartRate', '61', 'watch', '2026-03-02 00:00:00 +0100', '2026-03-02 00:00:00 +0100'),
    ])
c.execute("INSERT INTO workouts VALUES (2, 'HKWorkoutActivityTypeWalking', 42, 'min', 3.1, 'km', '2026-03-02 17:00:00 +0100')")
c.commit()
PY
run() { "$here/ce-apple-health" --db "$tmp/h.db"; }
out=$(run); echo "$out"
python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["new"]==1, s' "$out"
# Highest source per day (phone 4000 over watch 3500), newest import only (not 8000).
"$CE" search '"4000 steps"' | grep -q apple-health-month || { echo "step count wrong"; exit 1; }
"$CE" search '"resting HR 61"' | grep -q . || { echo "resting HR missing"; exit 1; }
"$CE" search walking | grep -q . || { echo "workout missing"; exit 1; }
out=$(run); python3 -c 'import json,sys; s=json.loads(sys.argv[1]); assert s["unchanged"]==1, s' "$out"
echo "ok: ce-apple-health"
