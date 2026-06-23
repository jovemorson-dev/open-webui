#!/usr/bin/env bash
# Starts cloudflared tunnel for nexus-relay, captures URL, publishes to GitHub.
# Designed to run as a systemd service — stays alive tracking the tunnel process.
set -euo pipefail

RELAY_PORT="${NEXUS_RELAY_PORT:-4242}"
URL_FILE="/mnt/Hive/Nexus/Runtime/relay_url.txt"
LOG_FILE="/tmp/nexus-relay-cf.log"
KEYS_FILE="/opt/nexus/config/api_keys.json"
REPO="jovemorson-dev/open-webui"
BRANCH="claude/mainframe-access-7e1sl3"
GH_FILE="nexus_relay_url.txt"

log() { echo "[relay-tunnel] $*"; }

# Kill any stale tunnel
pkill -f "cloudflared.*$RELAY_PORT" 2>/dev/null || true
sleep 1
rm -f "$LOG_FILE"

# Start tunnel in background
cloudflared tunnel --url "http://localhost:$RELAY_PORT" --no-autoupdate \
    >> "$LOG_FILE" 2>&1 &
CF_PID=$!
log "cloudflared PID $CF_PID"

# Wait up to 30s for URL
URL=""
for i in $(seq 1 15); do
    URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | head -1 || true)
    [[ -n "$URL" ]] && break
    sleep 2
done

if [[ -z "$URL" ]]; then
    log "ERROR: cloudflared never printed a URL — check $LOG_FILE"
    cat "$LOG_FILE" >&2
    wait $CF_PID; exit 1
fi

log "Tunnel URL: $URL"
mkdir -p "$(dirname "$URL_FILE")"
echo "$URL" > "$URL_FILE"

# Push URL to GitHub so Claude can always find it
GH_TOKEN=""
if [[ -f "$KEYS_FILE" ]]; then
    GH_TOKEN=$(python3 -c "
import json, sys
try:
    print(json.load(open('$KEYS_FILE')).get('github',''))
except: print('')
" 2>/dev/null || true)
fi

if [[ -n "$GH_TOKEN" ]]; then
    CONTENT=$(echo -n "$URL" | base64 -w0)
    # Get existing file SHA (needed for update)
    SHA=$(curl -sf -H "Authorization: token $GH_TOKEN" \
        "https://api.github.com/repos/$REPO/contents/$GH_FILE?ref=$BRANCH" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || true)

    PAYLOAD=$(python3 -c "
import json
d = {'message': 'relay url update', 'content': '$CONTENT', 'branch': '$BRANCH'}
sha = '$SHA'
if sha: d['sha'] = sha
print(json.dumps(d))
")
    HTTP=$(curl -sf -o /dev/null -w "%{http_code}" -X PUT \
        -H "Authorization: token $GH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "https://api.github.com/repos/$REPO/contents/$GH_FILE" 2>/dev/null || echo "000")
    log "GitHub push: HTTP $HTTP"
else
    log "No GitHub token in $KEYS_FILE — skipping push (Claude will need URL manually)"
fi

# Stay alive with the tunnel
log "Tracking tunnel process $CF_PID..."
wait $CF_PID
log "cloudflared exited — systemd will restart"
