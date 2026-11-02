"""Task-owned ephemeral HTTP fixture. Never records request contents."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path.startswith("/redirect/"):
            self.send_response(302)
            self.send_header("Location", "https://example.invalid/never-contact")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        if self.path.startswith("/oversized/"):
            self.send_header("Content-Length", str(3 * 1024 * 1024))
        self.end_headers()
        if self.path.startswith("/oversized/"):
            return
        frames = [
            {"choices": [{"delta": {"reasoning_content": "Provider summary"}}]},
            {"choices": [{"delta": {"content": "你好 **world**"}}]},
        ]
        try:
            for frame in frames:
                payload = ("data: " + json.dumps(frame, ensure_ascii=False) + "\r\n\r\n").encode()
                for offset in range(0, len(payload), 3):
                    self.wfile.write(payload[offset:offset + 3])
                    self.wfile.flush()
                    time.sleep(0.001)
            if self.path.startswith("/cancel/"):
                time.sleep(3)
            if self.path.startswith("/truncated/"):
                return
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
