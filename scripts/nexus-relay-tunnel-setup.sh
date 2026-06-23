#!/usr/bin/env bash
# One-shot setup: installs nexus-relay-tunnel as a persistent systemd service.
# Run with: sudo bash nexus-relay-tunnel-setup.sh [github-token]
set -euo pipefail

GH_TOKEN="${1:-}"
SCRIPT_SRC="$(dirname "$0")/nexus-relay-tunnel.sh"
SCRIPT_DST="/opt/nexus/relay/nexus-relay-tunnel.sh"
KEYS_FILE="/opt/nexus/config/api_keys.json"

echo "[setup] Installing nexus-relay-tunnel..."

# Download script if not running from repo
if [[ ! -f "$SCRIPT_SRC" ]]; then
    curl -fsSL \
      https://raw.githubusercontent.com/jovemorson-dev/open-webui/claude/mainframe-access-7e1sl3/scripts/nexus-relay-tunnel.sh \
      -o /tmp/nexus-relay-tunnel.sh
    SCRIPT_SRC=/tmp/nexus-relay-tunnel.sh
fi
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"

# Optionally save GitHub token
if [[ -n "$GH_TOKEN" ]]; then
    python3 - "$GH_TOKEN" "$KEYS_FILE" <<'PY'
import json, sys, pathlib
token = sys.argv[1]
path  = pathlib.Path(sys.argv[2])
path.parent.mkdir(parents=True, exist_ok=True)
data  = json.loads(path.read_text()) if path.exists() else {}
data["github"] = token
path.write_text(json.dumps(data, indent=2))
print(f"[setup] GitHub token saved to {path}")
PY
fi

# Create systemd service
cat > /etc/systemd/system/nexus-relay-tunnel.service <<EOF
[Unit]
Description=Nexus Claude Relay — Cloudflared Tunnel
After=network-online.target nexus-relay.service
Wants=network-online.target
BindsTo=nexus-relay.service

[Service]
ExecStart=/opt/nexus/relay/nexus-relay-tunnel.sh
Restart=always
RestartSec=20
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nexus-relay-tunnel
systemctl restart nexus-relay-tunnel

sleep 8
URL=$(cat /mnt/Hive/Nexus/Runtime/relay_url.txt 2>/dev/null || echo "")
echo ""
if [[ -n "$URL" ]]; then
    echo "================================================"
    echo "  Relay tunnel live: $URL"
    echo "  Auto-restarts and pushes to GitHub on rotation"
    echo "================================================"
else
    echo "[setup] Tunnel still starting — check: journalctl -u nexus-relay-tunnel -f"
fi
