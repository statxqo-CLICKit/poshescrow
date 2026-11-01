#!/usr/bin/env bash
# Pull all sign-ups from the posh-signups Worker (/export.csv) and append any rows whose id
# is not yet in the "POSH Escrow Sign-ups" Google Sheet (status column set to "new").
# Needs: gws CLI authenticated as statxqo@gmail.com (in Hark: shell credentials [{"provider":"google"}]).
# Values are written RAW so a sign-up can never inject a spreadsheet formula. Never prints the admin key.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_URL="${WORKER_URL:-https://posh-signups.statxqo.workers.dev}"
SHEET_ID="${SHEET_ID:-1e08ly-SjDgxqSWaQ0YCl9i_Z10cBQfKRfErMmPfZB90}"
TAB="${TAB:-Sign-ups}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

curl -sf "$WORKER_URL/export.csv" -H "Authorization: Bearer $(cat "$DIR/ADMIN_KEY")" -o "$TMP/export.csv"
gws sheets spreadsheets values get --params "{\"spreadsheetId\":\"$SHEET_ID\",\"range\":\"$TAB!A:A\"}" > "$TMP/ids.json"

python3 - "$TMP" <<'PY'
import csv, json, sys, os
tmp = sys.argv[1]
have = {r[0] for r in json.load(open(os.path.join(tmp, "ids.json"))).get("values", [])[1:] if r}
rows = list(csv.DictReader(open(os.path.join(tmp, "export.csv"), newline="", encoding="utf-8")))
cols = ["id","createdAt","receivedAt","source","username","displayName","role","wallet","email","marketingOptIn","roundOneInterest","consentText","userAgent","referrer"]
new = [[r.get(c, "") for c in cols] + ["new"] for r in rows if r["id"] not in have]
json.dump({"values": new}, open(os.path.join(tmp, "append.json"), "w"))
print(f"export rows: {len(rows)}, already in sheet: {len(have)}, new to append: {len(new)}")
PY

if [ "$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['values']))" "$TMP/append.json")" != "0" ]; then
  gws sheets spreadsheets values append \
    --params "{\"spreadsheetId\":\"$SHEET_ID\",\"range\":\"$TAB!A1\",\"valueInputOption\":\"RAW\",\"insertDataOption\":\"INSERT_ROWS\"}" \
    --json "$(cat "$TMP/append.json")" | python3 -c "import json,sys;d=json.load(sys.stdin);print('appended range:',d.get('updates',{}).get('updatedRange'))"
fi
