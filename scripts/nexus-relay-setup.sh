#!/usr/bin/env bash
# Sets up Claude's persistent relay access point on the Nexus Mainframe.
# Run once: bash nexus-relay-setup.sh
# After running, paste the printed URL to Claude.
set -euo pipefail

RELAY_SCRIPT="/opt/nexus/relay/nexus-relay.py"
RELAY_PORT="4242"
RELAY_TOKEN="nexus-relay-21"
URL_FILE="/mnt/Hive/Nexus/Runtime/relay_url.txt"
REPO_DIR="${REPO_DIR:-}"

echo "[setup] Installing nexus-relay..."

# Copy relay script into place
mkdir -p /opt/nexus/relay
# Download from GitHub if not running from repo
if [[ -f "$(dirname "$0")/nexus-relay.py" ]]; then
    cp "$(dirname "$0")/nexus-relay.py" "$RELAY_SCRIPT"
else
    curl -fsSL \
      https://raw.githubusercontent.com/jovemorson-dev/open-webui/claude/mainframe-access-7e1sl3/scripts/nexus-relay.py \
      -o "$RELAY_SCRIPT"
fi
chmod +x "$RELAY_SCRIPT"

# Create systemd service
cat > /etc/systemd/system/nexus-relay.service <<EOF
[Unit]
Description=Nexus Claude Relay
After=network.target

[Service]
ExecStart=/usr/bin/python3 $RELAY_SCRIPT
Restart=always
RestartSec=5
Environment=NEXUS_RELAY_TOKEN=$RELAY_TOKEN
Environment=NEXUS_RELAY_PORT=$RELAY_PORT
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nexus-relay
systemctl restart nexus-relay
sleep 2
systemctl is-active nexus-relay && echo "[setup] nexus-relay service: active" || echo "[setup] WARNING: service not active"

# Start cloudflared quick tunnel (HTTP → localhost:4242)
echo "[setup] Starting cloudflared tunnel..."
mkdir -p /mnt/Hive/Nexus/Runtime

# Kill any existing relay tunnel
pkill -f "cloudflared.*4242" 2>/dev/null || true
sleep 1

# Start tunnel in background, capture URL
nohup cloudflared tunnel --url "http://localhost:$RELAY_PORT" --no-autoupdate \
    > /tmp/nexus-relay-cf.log 2>&1 &
CF_PID=$!
echo $CF_PID > /tmp/nexus-relay-cf.pid

# Wait for URL to appear
echo "[setup] Waiting for tunnel URL..."
for i in $(seq 1 20); do
    URL=$(grep -o 'https://[a-z0-9\-]*\.trycloudflare\.com' /tmp/nexus-relay-cf.log 2>/dev/null | head -1 || true)
    if [[ -n "$URL" ]]; then break; fi
    sleep 2
done

if [[ -z "$URL" ]]; then
    echo "[setup] ERROR: Could not get cloudflared URL. Check /tmp/nexus-relay-cf.log"
    cat /tmp/nexus-relay-cf.log
    exit 1
fi

# Save URL
echo "$URL" > "$URL_FILE"
echo "[setup] Relay URL: $URL"

# Push URL to GitHub if repo is available
if [[ -z "$REPO_DIR" ]]; then
    REPO_DIR=$(find ~ /opt /mnt/Hive -maxdepth 5 -name ".git" -type d 2>/dev/null \
        | xargs -I{} dirname {} | grep -v "\.claude" | head -1 || true)
fi

if [[ -n "$REPO_DIR" && -d "$REPO_DIR/.git" ]]; then
    cd "$REPO_DIR"
    echo "$URL" > nexus_relay_url.txt
    git add nexus_relay_url.txt
    git commit -m "update nexus relay URL $(date +%Y%m%d_%H%M)" 2>/dev/null || true
    git push -u origin claude/mainframe-access-7e1sl3 2>/dev/null && \
        echo "[setup] URL pushed to GitHub" || echo "[setup] GitHub push failed — use URL above"
fi

echo ""
echo "================================================"
echo "  PASTE THIS TO CLAUDE:"
echo "  Relay URL: $URL"
echo "  Token: $RELAY_TOKEN"
echo "================================================"
echo ""
echo "Test: curl -H 'Authorization: Bearer $RELAY_TOKEN' $URL/ping"
