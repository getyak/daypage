"""Task-owned loopback fixture. Synthetic UI tests only; never logs request text/keys."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"GET-326-local-fixture")
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        size = int(self.headers.get("Content-Length", "0"))
        if size > 200_000:
            self.send_error(413)
            return
        payload = json.loads(self.rfile.read(size))
        assert payload.get("model") == "fixture-model"
        assert not self.headers.get("Authorization"), "Anonymous fixture must not receive any key"
        assert not payload.get("tools"), "Note chat has no tool capability"
        content = json.dumps({"choices": [{"message": {"content": "Fixture reply: these excerpts are local synthetic notes. Your own configured AI will answer here."}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18763), Handler).serve_forever()
