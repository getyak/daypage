"""Task-owned ephemeral HTTP fixture. Never records request contents."""
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.path.startswith("/fresh-tools/"):
            payload = json.loads(raw)
            serialized = json.dumps(payload)
            assert "REMOVED_PRIVATE_NOTE_388" not in serialized, "A deleted cached note reached the provider"
            assert "REMOVED_PRIVATE_RELATION_388" not in serialized, "Deleted relation evidence reached the provider"
            results = [m for m in payload["messages"] if m.get("role") == "tool"]
            if not results:
                reply = {"choices": [{"finish_reason": "tool_calls", "message": {
                    "role": "assistant", "tool_calls": [{"id": "fresh-relations", "type": "function",
                    "function": {"name": "relations_list", "arguments": "{}"}}]}}]}
            else:
                result = json.loads(results[-1]["content"])
                assert result["total"] == 1, "An authorized missing connection must remain visible as a marker"
                edge = result["relations"][0]
                assert edge["to_missing"] is True and edge["to"]["snippet"] == ""
                reply = {"choices": [{"finish_reason": "stop", "message": {
                    "role": "assistant", "content": "Fresh scope verified."}}]}
            content = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return
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
