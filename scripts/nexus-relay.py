#!/usr/bin/env python3
"""
Nexus AI Relay — persistent access point for any AI agent.
Any AI (Claude, Codex, Open Interpreter, etc.) can connect, read context,
write session memory, and pick up exactly where the last session left off.

Usage:
  GET  /connect           — full onboarding dump: context + status + punchlist + commands
  GET  /status            — quick system health
  GET  /context           — last session's handoff notes
  POST /context           — write session summary before leaving
  GET  /memory            — all persistent key/value memory
  POST /memory            — store key/value pairs
  GET  /punchlist         — current task list
  GET  /logs              — recent logs
  GET  /services          — service health
  GET  /docker            — container status
  GET  /runtime           — runtime state
  GET  /doctrine          — operational doctrine
  GET  /ai-logs           — AI session logs
  GET  /help              — list all endpoints

Auth: Authorization: Bearer nexus-relay-21
"""
import subprocess, json, os, time, sys, pathlib
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime

TOKEN    = os.environ.get("NEXUS_RELAY_TOKEN", "nexus-relay-21")
HOST     = "127.0.0.1"
PORT     = int(os.environ.get("NEXUS_RELAY_PORT", "4242"))
HIVE     = "/mnt/Hive/Nexus"
MEM_FILE = f"{HIVE}/Memory/ai_relay_memory.json"
CTX_FILE = f"{HIVE}/Memory/ai_session_context.json"


# ── Persistent memory helpers ────────────────────────────────────────────────

def read_json(path, default):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except Exception:
        return default

def write_json(path, data):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(path).write_text(json.dumps(data, indent=2))


def load_memory():
    return read_json(MEM_FILE, {})

def save_memory(data):
    write_json(MEM_FILE, data)

def load_context():
    return read_json(CTX_FILE, {
        "last_ai": None,
        "last_seen": None,
        "session_summary": "No previous session recorded.",
        "active_tasks": [],
        "notes": [],
    })

def save_context(ctx):
    write_json(CTX_FILE, ctx)


# ── Shell command runner ─────────────────────────────────────────────────────

def run(cmd, timeout=60):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, shell=isinstance(cmd, str))
        return r.stdout + (f"\n[stderr]: {r.stderr}" if r.stderr.strip() else "")
    except subprocess.TimeoutExpired:
        return "[timeout]"
    except Exception as e:
        return f"[error]: {e}"


SHELL_COMMANDS = {
    "status":    "uptime && echo && free -h && echo && df -h /",
    "services":  "for s in tailscaled smbd docker nexus-habitat open-webui habitat; do "
                 "systemctl is-active $s 2>/dev/null && echo \"$s: active\" || echo \"$s: inactive\"; done",
    "docker":    "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo 'docker not running'",
    "punchlist": f"cat {HIVE}/NEXUS_PUNCHLIST.md 2>/dev/null || echo '(not found)'",
    "runtime":   f"ls -la {HIVE}/Runtime/ 2>/dev/null && "
                 f"find {HIVE}/Runtime -type f | xargs -I{{}} sh -c 'echo === {{}} === && cat \"{{}}\"' 2>/dev/null",
    "logs":      f"find {HIVE}/Logs -type f 2>/dev/null | sort | tail -5 | "
                 "xargs -I{} sh -c 'echo === {} === && tail -80 \"{}\"'",
    "ai-logs":   f"find {HIVE}/ai-logs -type f 2>/dev/null | sort | tail -3 | "
                 "xargs -I{} sh -c 'echo === {} === && tail -80 \"{}\"'",
    "doctrine":  f"find {HIVE}/Doctrine -type f | xargs -I{{}} sh -c 'echo === {{}} === && cat \"{{}}\"' 2>/dev/null",
    "deployment":f"ls -la {HIVE}/Deployment/ 2>/dev/null",
    "chats":     f"ls -lt {HIVE}/Chats/ 2>/dev/null | head -20",
    "disk":      "df -hT",
    "processes": "ps aux --sort=-%cpu | head -20",
    "journal":   "journalctl -n 100 --no-pager -p warning 2>/dev/null || true",
    "report":    "bash /mnt/Hive/Scripts/system_report.sh 2>/dev/null",
}


# ── Request handler ──────────────────────────────────────────────────────────

class RelayHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        if not self._auth(): return
        path = self.path.lstrip("/").split("?")[0]

        if path == "" or path == "connect":
            self._handle_connect()
        elif path == "context":
            self._json(200, load_context())
        elif path == "memory":
            self._json(200, load_memory())
        elif path == "help":
            self._json(200, {"endpoints": list(SHELL_COMMANDS.keys()) + ["connect","context","memory","help"]})
        elif path in SHELL_COMMANDS:
            self._json(200, {"cmd": path, "output": run(SHELL_COMMANDS[path]), "ts": time.time()})
        else:
            self._json(404, {"error": f"unknown: {path}", "try": "/help"})

    def do_POST(self):
        if not self._auth(): return
        path = self.path.lstrip("/").split("?")[0]
        body = self._body()

        if path == "context":
            ctx = load_context()
            ctx.update({
                "last_ai":         body.get("ai", "unknown"),
                "last_seen":       datetime.utcnow().isoformat() + "Z",
                "session_summary": body.get("summary", ctx["session_summary"]),
                "active_tasks":    body.get("active_tasks", ctx["active_tasks"]),
                "notes":           body.get("notes", ctx["notes"]),
            })
            save_context(ctx)
            self._json(200, {"saved": True, "context": ctx})

        elif path == "memory":
            mem = load_memory()
            mem.update(body)
            save_memory(mem)
            self._json(200, {"saved": True, "keys": list(mem.keys())})

        else:
            self._json(404, {"error": f"unknown POST: {path}"})

    # ── /connect — full onboarding for a new AI session ──────────────────────

    def _handle_connect(self):
        ctx = load_context()
        mem = load_memory()
        status  = run(SHELL_COMMANDS["status"])
        svcs    = run(SHELL_COMMANDS["services"])
        punch   = run(SHELL_COMMANDS["punchlist"])
        docker_ = run(SHELL_COMMANDS["docker"])

        self._json(200, {
            "welcome": "Nexus Mainframe Relay — you are now tethered.",
            "instructions": (
                "1. Read 'previous_session' to understand context from the last AI. "
                "2. Read 'punchlist' for active tasks. "
                "3. Use GET /<command> to query the system. "
                "4. Before ending your session, POST /context with your summary so the next AI picks up seamlessly. "
                "5. POST /memory to store anything worth remembering persistently."
            ),
            "previous_session": ctx,
            "persistent_memory": mem,
            "system_status": status,
            "services": svcs,
            "docker": docker_,
            "punchlist": punch,
            "available_commands": list(SHELL_COMMANDS.keys()),
            "write_endpoints": {
                "POST /context": {"ai": "str", "summary": "str", "active_tasks": ["..."], "notes": ["..."]},
                "POST /memory":  {"any_key": "any_value"},
            },
            "ts": time.time(),
        })

    # ── Helpers ───────────────────────────────────────────────────────────────

    def _auth(self):
        if self.headers.get("Authorization", "") != f"Bearer {TOKEN}":
            self._json(401, {"error": "unauthorized", "hint": f"Authorization: Bearer {TOKEN}"})
            return False
        return True

    def _body(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            return json.loads(self.rfile.read(length)) if length else {}
        except Exception:
            return {}

    def _json(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[relay] {self.address_string()} — {fmt % args}\n")


if __name__ == "__main__":
    pathlib.Path(f"{HIVE}/Memory").mkdir(parents=True, exist_ok=True)
    print(f"[nexus-relay] Listening on {HOST}:{PORT}  token={TOKEN}", flush=True)
    HTTPServer((HOST, PORT), RelayHandler).serve_forever()
