"""
"""
import sys, json, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
LOG = sys.argv[2] if len(sys.argv) > 2 else "mock_web.log"
KNOWN = {"P0001", "P0431", "P0432"}

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + self.path + " " + body + "\n")
        accepted = 0
        try:
            obj = json.loads(body)
            items = obj.get("items", [obj])
            accepted = sum(1 for it in items
                           if isinstance(it, dict) and it.get("point_id") in KNOWN
                           and it.get("severity") in (0, 1, 2))
        except Exception:
            pass
        resp = json.dumps({"accepted": accepted, "rejected": [],
                           "server_time": int(time.time() * 1000)}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)

    def do_GET(self):
        if self.path.startswith("/api/health"):
            b = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        print("[mock]", fmt % args)

if __name__ == "__main__":
    print(f"mock web listening on 0.0.0.0:{PORT}, log={LOG}")
    HTTPServer(("0.0.0.0", PORT), H).serve_forever()
