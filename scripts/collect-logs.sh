#!/usr/bin/env bash
# Pull Cyanide diagnostic logs from R2 into logs/ in this repo.
# Idempotent — only downloads keys not already present locally.
#
# Auth: needs the BrokenBlade worker ADMIN_TOKEN. Resolution order:
#   1. $BB_ADMIN_TOKEN env var
#   2. first line of ~/Downloads/brokenblade-admin-token.txt

set -euo pipefail

WORKER_URL="https://brokenblade-weblogs.hackerboii.workers.dev"
TOKEN_FILE="$HOME/Downloads/brokenblade-admin-token.txt"
ADMIN_TOKEN="${BB_ADMIN_TOKEN:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/logs"

if [ -z "$ADMIN_TOKEN" ]; then
  if [ -f "$TOKEN_FILE" ]; then
    ADMIN_TOKEN=$(head -1 "$TOKEN_FILE" | tr -d '\n\r')
  else
    echo "ERROR: no admin token. Set BB_ADMIN_TOKEN or put it in $TOKEN_FILE" >&2
    exit 1
  fi
fi

WORK_DIR=$(mktemp -d)
LIST_JSON="$WORK_DIR/list.json"
NEW_KEYS="$WORK_DIR/new_keys.txt"
trap 'command -v trash >/dev/null && trash "$WORK_DIR" 2>/dev/null || true' EXIT

echo "fetching key list from $WORKER_URL ..."
curl -fsS -H "X-Admin-Token: $ADMIN_TOKEN" \
  "$WORKER_URL/admin/list?prefix=cyanide/" > "$LIST_JSON"

mkdir -p "$DEST"

python3 - "$LIST_JSON" "$DEST" "$NEW_KEYS" <<'PY'
import json, os, sys
list_path, dest, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
remote = set(json.load(open(list_path)).get('keys', []))
local = set()
for dp, _, fs in os.walk(dest):
    for f in fs:
        if f.endswith('.txt'):
            local.add('cyanide/' + os.path.relpath(os.path.join(dp, f), dest))
new_keys = sorted(remote - local)
with open(out_path, 'w') as o:
    for k in new_keys:
        o.write(k + '\n')
print(f'remote: {len(remote)}  local: {len(local)}  new: {len(new_keys)}')
PY

new_count=$(grep -c . "$NEW_KEYS" || true)
if [ "$new_count" -eq 0 ]; then
  echo "already up to date."
else
  ok=0; fail=0
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    rel="${key#cyanide/}"
    out="$DEST/$rel"
    mkdir -p "$(dirname "$out")"
    tmp_out=$(mktemp "$WORK_DIR/download.XXXXXX")
    http=$(curl -sS -o "$tmp_out" -w '%{http_code}' \
      -H "X-Admin-Token: $ADMIN_TOKEN" \
      "$WORKER_URL/log/$key" || echo "000")
    if [ "$http" = "200" ]; then
      mv "$tmp_out" "$out"
      ok=$((ok+1))
    else
      fail=$((fail+1))
      echo "FAIL ($http) $key" >&2
    fi
  done < "$NEW_KEYS"
  echo "downloaded: $ok  failed: $fail"
fi

echo
echo "=== per-build-tag breakdown ==="
for d in "$DEST"/cyanide-*; do
  [ -d "$d" ] || continue
  printf '%-30s %4d\n' "$(basename "$d")" "$(find "$d" -type f -name '*.txt' | wc -l | tr -d ' ')"
done
