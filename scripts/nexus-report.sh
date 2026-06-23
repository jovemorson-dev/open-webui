#!/usr/bin/env bash
# Run on mainframe — collects system state + logs, pushes to GitHub so Claude can read it
set -euo pipefail

HIVE="/mnt/Hive/Nexus"
REPO_DIR="$HOME/open-webui"
BRANCH="claude/mainframe-access-7e1sl3"
OUT="$REPO_DIR/nexus_state.md"

echo "[nexus-report] Gathering system state..."

{
cat <<HEADER
# Nexus Mainframe State Report
Generated: $(date -Is)

## System
HEADER

hostnamectl 2>/dev/null || true
echo
uptime
echo
echo "## Disk"
df -hT
echo
echo "## Memory"
free -h
echo
echo "## Services"
systemctl is-active --quiet tailscaled && echo "tailscaled: active" || echo "tailscaled: inactive"
systemctl is-active --quiet smbd       && echo "smbd: active"       || echo "smbd: inactive"
systemctl is-active --quiet docker     && echo "docker: active"     || echo "docker: inactive"
echo
echo "## Network"
ip -br a
echo
echo "## Running Containers"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "docker not running"
echo

echo "## Nexus Punchlist"
echo '```'
cat "$HIVE/NEXUS_PUNCHLIST.md" 2>/dev/null || echo "(not found)"
echo '```'
echo

echo "## Nexus Verification Log"
echo '```'
cat "$HIVE/NEXUS_VERIFICATION_LOG.md" 2>/dev/null || echo "(not found)"
echo '```'
echo

echo "## AI Logs (latest 100 lines)"
echo '```'
find "$HIVE/ai-logs" -type f -name "*.log" -o -name "*.txt" 2>/dev/null \
  | sort -t_ -k1 | tail -3 \
  | xargs -I{} sh -c 'echo "=== {} ===" && tail -50 "{}"' 2>/dev/null || echo "(none)"
echo '```'
echo

echo "## Runtime"
echo '```'
ls -la "$HIVE/Runtime/" 2>/dev/null || echo "(empty)"
echo '```'
echo

echo "## Doctrine (latest)"
echo '```'
ls -la "$HIVE/Doctrine/" 2>/dev/null
find "$HIVE/Doctrine" -type f | head -5 | xargs -I{} sh -c 'echo "=== {} ===" && cat "{}"' 2>/dev/null || true
echo '```'
echo

echo "## Deployment"
echo '```'
ls -la "$HIVE/Deployment/" 2>/dev/null || echo "(empty)"
echo '```'
echo

echo "## Chats (recent)"
echo '```'
ls -lt "$HIVE/Chats/" 2>/dev/null | head -20 || echo "(empty)"
echo '```'
echo

echo "## Memory"
echo '```'
ls -la "$HIVE/Memory/" 2>/dev/null || echo "(empty)"
find "$HIVE/Memory" -type f | xargs -I{} sh -c 'echo "=== {} ===" && cat "{}"' 2>/dev/null || true
echo '```'
echo

echo "## Hive Scripts"
echo '```'
for f in /mnt/Hive/Scripts/*.sh; do
  echo "=== $f ==="
  cat "$f"
  echo
done
echo '```'

echo "## Nexus Logs (last 200 lines)"
echo '```'
find "$HIVE/Logs" -type f | sort | tail -5 | xargs -I{} sh -c 'echo "=== {} ===" && tail -100 "{}"' 2>/dev/null || echo "(none)"
echo '```'

} > "$OUT"

echo "[nexus-report] Written to $OUT"

# Push to git
cd "$REPO_DIR"
git fetch origin "$BRANCH" 2>/dev/null || true
git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
git add nexus_state.md
git commit -m "nexus state report $(date +%Y%m%d_%H%M%S)" || echo "[nexus-report] Nothing new to commit"
git push -u origin "$BRANCH"

echo "[nexus-report] Done — Claude can now read nexus_state.md from GitHub"
