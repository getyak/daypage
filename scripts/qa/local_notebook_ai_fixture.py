"""Task-owned loopback fixture. Synthetic UI tests only; never logs request text/keys."""
import base64
import json
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


SPEECH_SAMPLE = "This is a short DayPage speech sample. Your notes stay private during this test."
# Six seconds of mono Layer III audio: a quiet 0.1-second 440 Hz tone, then silence.
# Generated from synthetic PCM at 22,050 Hz / 32 kbit/s. Embedded so hosted UI tests
# need only Python's standard library; these are complete, decodable MP3 frames.
SPEECH_MP3 = zlib.decompress(base64.b64decode("""
eJzt2F1MU3cYx/F/W15KOZNCWTyGMsCZGTtZuoFb9EJqFSMv03aDMicbLwaCc0NcMW4SsIwNaobZECIdMAORl4liMFPTuikdJYgg
kVVdhOmYhAXchSyBBM26ntF767InxJD099yenHzz+ee5eoRZTR9TPKrMfP4dnpX1+F1NLa5KLM54+5PIEZ141OL86MgvU582OgM2
HLA+nMzlD0cN9OUec1h5nu8unWAa+VCFq91YX5b56s2HD+Y36BQhkz8FpkkSWuV/jN9zWk0jHBcgLrfbmTCr7QtevufjL3oadIzJ
0irGDFlmi1orm7l/Vn27OpBdT/ZLHJPv618fnSyJ1rs2SYreKAvTqER6f/dz9vMq89c2YaDKMRE6PTcjXO09J507tGVjVKSgCgv4
vCW6oEuxYpnOph6M5IQFUFC42qDU/8ZYoN1ib0ri+M0FjmoFt2bryDVXVUhDevxgdulAZZF9i5gL1txRS6+LmH/Q9ogPdhvWHc26
3ZTrKLxwbXru8MF9P3cI84L7xqmymIgTe5eJu3k/02OTqdESUmnzgBTh/Lv8y+/L2ZECo8UaKqrVmKNGV+hrBzotnN/9Cl0Mv0pU
s/CMcX92jOVVvfXPD5c7b51fPe6ecX6bIZT0tDTduCd8b1PJxCZTdzMXzX6VduhjckJzc5oVUZPv5Te052j7bR7QCxHnLn1Y2tjM
DIWalDPr/OOGH6WaS47GJ/31eptpWOQfbDyUY9RKq+sv343lN4YapbF/X1m/amRI7qyfH98/+GKSVplcJ8sSHn9T7oiTVOYHJris
2crX+Pj8Hbul5b37hzoz0z0gWVjB2FrRnW3s97yaqa2mi19yzUOd2+0pn+08PrpLn17sTLhVKGsTmze/ZEhUf7cytUFZ1yVtO/1V
3Y+6EzWq4APCzAN3yfHZuxdSN72ZGP+KOv1J4wEpGZNsYwvzhO9P+/f/jAd08CmdRQxp+lqfEegkQKQQQMQOQNQQQMQOQNQQQMQO
QNQQQMQOQNQQQMQOQNQQQMSOj4EWq/MMQUvj4QDyHgKI2AGIGgKI2AGIGgKI2AGIGgKI2AGIGgKI2AGIGgKI2AGIGgKI2AGIGloa
INz/vHZ8bBMA8h4CiNgBiBoCiNgBiBoCiNgBiBoCiNgBiBoCiNgBiBoCiNgBiBoCiNjxMRDuf147PrYJAHkPAUTsAEQNAUTsAEQN
AUTsAEQNAUTsAEQNAUTsAEQNAUTsAEQNAUTs+BgI9z+vHR/bBIC8hwAidgCihgAidgCihgAidgCihgAidgCihgAidpYIaLHmP0GL
Nf8CFufPaA==
"""))
TOOL_NAMES = {"notes_search", "notes_read", "notes_list", "notes_stats", "notes_tags", "assets_read"}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"GET-326-local-fixture")
        elif self.path == "/v1/models":
            assert not self.headers.get("Authorization"), "Anonymous fixture must not receive a key"
            content = json.dumps({"data": [{"id": "fixture-model"}, {"id": "fixture-alternative"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        else:
            self.send_error(404)

    def do_POST(self):
        route = urlsplit(self.path)
        if route.path in ("/v1/audio/speech", "/failure/v1/audio/speech") or route.path.startswith("/v1/text-to-speech/"):
            self.speech(route)
            return
        if self.path not in ("/v1/chat/completions", "/slow/v1/chat/completions"):
            self.send_error(404)
            return
        size = int(self.headers.get("Content-Length", "0"))
        if size > 200_000:
            self.send_error(413)
            return
        payload = json.loads(self.rfile.read(size))
        assert payload.get("model") == "fixture-model"
        assert not self.headers.get("Authorization"), "Anonymous fixture must not receive any key"
        if any(message.get("role") == "user" and message.get("content") == "Talk without reading any note excerpts"
               for message in payload.get("messages", [])):
            assert not payload.get("tools"), "Disabling note excerpts must remove every tool capability"
            assert "A good notebook leaves room for unfinished thoughts." not in json.dumps(payload)
        if payload.get("tools"):
            self.tools(payload)
            return
        # Keep the legacy no-tools contract strict for every ordinary chat request.
        assert not payload.get("tools"), "Note chat has no tool capability"
        if self.path == "/slow/v1/chat/completions":
            time.sleep(5)
        if payload.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            chunks = [
                {"reasoning_content": "I will use only the supplied excerpts."},
                {"content": "Fixture reply: **local synthetic notes**.\n\n"},
                {"content": "## A small reflection\n\n- One idea to keep\n- One question to revisit\n\n"},
                {"content": "```swift\nlet thought = \"keep\"\n```\n\n"},
                {"content": "| Thought | Next step |\n| --- | --- |\n| A walk | Keep noticing |\n"},
            ]
            try:
                for delta in chunks:
                    frame = {"choices": [{"delta": delta}]}
                    self.wfile.write(("data: " + json.dumps(frame) + "\n\n").encode())
                    self.wfile.flush()
                    time.sleep(0.35)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.json_response({"choices": [{"message": {"content": "Fixture reply: these excerpts are local synthetic notes. Your own configured AI will answer here."}}]})

    def tools(self, payload):
        assert not payload.get("stream"), "Tool turns must be complete nonstream responses"
        names = {tool["function"]["name"] for tool in payload["tools"]}
        assert names == TOOL_NAMES, "Only the six scoped read-only tools may be exposed"
        messages = payload["messages"]
        assert messages[0]["role"] == "system"
        results = [message for message in messages if message.get("role") == "tool"]
        if not results:
            self.json_response({"choices": [{"finish_reason": "tool_calls", "message": {
                "role": "assistant", "content": None,
                "tool_calls": [{"id": "fixture-notebook-search", "type": "function", "function": {
                    "name": "notes_search", "arguments": json.dumps({"query": "notebook", "limit": 8})}}],
            }}]})
            return
        result = results[-1]
        assert result["tool_call_id"] == "fixture-notebook-search"
        calls = [call for message in messages for call in message.get("tool_calls", [])]
        assert any(call["id"] == result["tool_call_id"] for call in calls)
        cards = json.loads(result["content"])["cards"]
        assert cards, "Synthetic notebook seed must produce a scoped source"
        source = cards[0]
        assert "notebook" in source["snippet"].lower()
        assert source["card_ref"] and source["day"]
        # Reply text and source identity come from the actual tool result, never a
        # substitute note. The native test opens that source and checks its original.
        reply = "Tool reply: " + source["snippet"] + "\n\nSource: " + source["day"] + " (" + source["card_ref"] + ")."
        self.json_response({"choices": [{"finish_reason": "stop", "message": {"role": "assistant", "content": reply}}]})

    def speech(self, route):
        size = int(self.headers.get("Content-Length", "0"))
        if size > 32_000:
            self.send_error(413)
            return
        payload = json.loads(self.rfile.read(size))
        assert self.headers.get("Accept") == "audio/mpeg"
        if route.path.startswith("/v1/text-to-speech/"):
            assert route.path == "/v1/text-to-speech/fixture-voice"
            assert parse_qs(route.query) == {"output_format": ["mp3_44100_128"]}
            assert self.headers.get("xi-api-key") == "fixture-speech-key"
            assert not self.headers.get("Authorization")
            assert payload["model_id"] == "fixture-tts"
            text = payload["text"]
        else:
            assert not self.headers.get("Authorization"), "Anonymous speech fixture must not receive a key"
            assert not self.headers.get("xi-api-key")
            assert payload["model"] == "fixture-tts"
            assert payload["voice"] == "fixture-voice"
            assert payload["response_format"] == "mp3"
            text = payload["input"]
        assert text == SPEECH_SAMPLE or text.startswith("Tool reply: "), "Speech fixtures accept synthetic text only"
        if route.path == "/failure/v1/audio/speech":
            self.json_response({"error": {"message": "Synthetic unauthorized speech response"}}, status=401)
            return
        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Content-Length", str(len(SPEECH_MP3)))
        self.end_headers()
        try:
            self.wfile.write(SPEECH_MP3)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def json_response(self, payload, status=200):
        content = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18763), Handler).serve_forever()
