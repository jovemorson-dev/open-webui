#!/usr/bin/env python3
"""
Nexus Relay — Claude's persistent access point to the mainframe.
Runs on localhost:4242, exposed via cloudflared quick tunnel.
Protected by bearer token. Whitelisted commands only.
"""
import subprocess, json, os, time, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

TOKEN = os.environ.get("NEXUS_RELAY_TOKEN", "nexus-relay-21")
HOST  = "127.0.0.1"
PORT  = int(os.environ.get("NEXUS_RELAY_PORT", "4242"))
HIVE  = "/mnt/Hive/Nexus"

COMMANDS = {
    "ping":         ["echo", "pong"],
    "status":       ["bash", "-c", "uptime && echo && free -h && echo && df -h /"],
    "services":     ["bash", "-c",
                     "for s in tailscaled smbd docker nexus-habitat open-webui habitat; do "
                     "  systemctl is-active $s 2>/dev/null && echo \"$s: active\" || echo \"$s: inactive\"; "
                     "done"],
    "docker":       ["docker", "ps", "--format",
                     "table {{.Names}}\t{{.Status}}\t{{.Ports}}"],
    "punchlist":    ["cat", f"{HIVE}/NEXUS_PUNCHLIST.md"],
    "verification": ["cat", f"{HIVE}/NEXUS_VERIFICATION_LOG.md"],
    "runtime":      ["bash", "-c",
                     f"ls -la {HIVE}/Runtime/ && "
                     f"find {HIVE}/Runtime -type f | xargs -I{{}} sh -c 'echo === {{}} === && cat \"{{}}\"' 2>/dev/null"],
    "logs":         ["bash", "-c",
                     f"find {HIVE}/Logs -type f 2>/dev/null | sort | tail -5 | "
                     "xargs -I{} sh -c 'echo === {} === && tail -80 \"{}\"'"],
    "ai-logs":      ["bash", "-c",
                     f"find {HIVE}/ai-logs -type f 2>/dev/null | sort | tail -3 | "
                     "xargs -I{} sh -c 'echo === {} === && tail -80 \"{}\"'"],
    "doctrine":     ["bash", "-c",
                     f"find {HIVE}/Doctrine -type f | xargs -I{{}} sh -c 'echo === {{}} === && cat \"{{}}\"' 2>/dev/null"],
    "memory":       ["bash", "-c",
                     f"find {HIVE}/Memory -type f | xargs -I{{}} sh -c 'echo === {{}} === && cat \"{{}}\"' 2>/dev/null"],
    "deployment":   ["bash", "-c", f"ls -la {HIVE}/Deployment/"],
    "chats":        ["bash", "-c", f"ls -lt {HIVE}/Chats/ | head -20"],
    "hive-scripts": ["bash", "-c",
                     "for f in /mnt/Hive/Scripts/*.sh; do echo === $f === && cat $f && echo; done"],
    "report":       ["bash", "/mnt/Hive/Scripts/system_report.sh"],
    "disk":         ["df", "-hT"],
    "processes":    ["bash", "-c", "ps aux --sort=-%cpu | head -20"],
    "journal":      ["bash", "-c",
                     "journalctl -n 100 --no-pager -p warning 2>/dev/null || true"],
}


class RelayHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not self._auth():
            return
        cmd = self.path.lstrip("/").split("?")[0] or "ping"
        self._run(cmd)

    def do_POST(self):
        if not self._auth():
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length)) if length else {}
        except Exception:
            body = {}
        cmd = body.get("cmd", self.path.lstrip("/").split("?")[0]) or "ping"
        self._run(cmd)

    def _auth(self):
        auth = self.headers.get("Authorization", "")
        if auth != f"Bearer {TOKEN}":
            self._respond(401, {"error": "unauthorized"})
            return False
        return True

    def _run(self, name):
        if name == "help" or name not in COMMANDS:
            self._respond(200 if name == "help" else 400, {
                "error": f"unknown command: {name}" if name != "help" else None,
                "available": list(COMMANDS.keys())
            })
            return
        try:
            result = subprocess.run(
                COMMANDS[name], capture_output=True, text=True, timeout=60
            )
            self._respond(200, {
                "cmd": name,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "rc": result.returncode,
                "ts": time.time(),
            })
        except subprocess.TimeoutExpired:
            self._respond(504, {"error": "timeout", "cmd": name})
        except Exception as e:
            self._respond(500, {"error": str(e), "cmd": name})

    def _respond(self, code, data):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[relay] {self.address_string()} {fmt % args}\n")


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), RelayHandler)
    print(f"[nexus-relay] Listening on {HOST}:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("[nexus-relay] Stopped")
