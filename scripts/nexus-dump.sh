#!/usr/bin/env bash
# Standalone — collects Nexus/Hive state and posts to pastebin, prints URL
set -euo pipefail

HIVE="/mnt/Hive/Nexus"

collect() {
  echo "# Nexus Mainframe Dump — $(date -Is)"
  echo
  echo "## System"
  hostnamectl 2>/dev/null || true
  uptime
  echo
  echo "## Disk"
  df -hT
  echo
  echo "## Memory"
  free -h
  echo
  echo "## Services"
  for s in tailscaled smbd docker open-webui habitat; do
    systemctl is-active "$s" 2>/dev/null && echo "$s: active" || echo "$s: inactive"
  done
  echo
  echo "## Containers"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "docker not running"
  echo
  echo "## Nexus Directory"
  ls -la "$HIVE/" 2>/dev/null || echo "(not found)"
  echo
  echo "## PUNCHLIST"
  cat "$HIVE/NEXUS_PUNCHLIST.md" 2>/dev/null || echo "(not found)"
  echo
  echo "## VERIFICATION LOG"
  cat "$HIVE/NEXUS_VERIFICATION_LOG.md" 2>/dev/null || echo "(not found)"
  echo
  echo "## Doctrine"
  find "$HIVE/Doctrine" -type f 2>/dev/null | while read -r f; do
    echo "=== $f ===" && cat "$f"
  done || echo "(empty)"
  echo
  echo "## Memory"
  find "$HIVE/Memory" -type f 2>/dev/null | while read -r f; do
    echo "=== $f ===" && cat "$f"
  done || echo "(empty)"
  echo
  echo "## Runtime"
  ls -la "$HIVE/Runtime/" 2>/dev/null || echo "(empty)"
  find "$HIVE/Runtime" -type f 2>/dev/null | while read -r f; do
    echo "=== $f ===" && cat "$f"
  done
  echo
  echo "## AI Logs (last 100 lines each)"
  find "$HIVE/ai-logs" -type f 2>/dev/null | sort | tail -5 | while read -r f; do
    echo "=== $f ===" && tail -100 "$f"
  done || echo "(none)"
  echo
  echo "## Nexus Logs (last 100 lines each)"
  find "$HIVE/Logs" -type f 2>/dev/null | sort | tail -5 | while read -r f; do
    echo "=== $f ===" && tail -100 "$f"
  done || echo "(none)"
  echo
  echo "## Hive Scripts"
  for f in /mnt/Hive/Scripts/*.sh; do
    echo "=== $f ===" && cat "$f"
  done
}

echo "[nexus-dump] Collecting..." >&2
DATA=$(collect)

# Try paste.rs first, fall back to ix.io
URL=$(echo "$DATA" | curl -s --data-binary @- https://paste.rs 2>/dev/null) \
  || URL=$(echo "$DATA" | curl -s -F 'f:1=<-' https://ix.io 2>/dev/null) \
  || URL=""

if [[ -n "$URL" ]]; then
  echo
  echo "================================================"
  echo "  PASTE THIS URL TO CLAUDE:"
  echo "  $URL"
  echo "================================================"
else
  echo "[nexus-dump] Pastebin failed — printing raw output:" >&2
  echo "$DATA"
fi
