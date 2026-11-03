"""Task-owned loopback fixture. Synthetic UI tests only; never logs request text/keys."""
import base64
import json
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


SPEECH_SAMPLE = "This is a short DayPage speech sample. Your notes stay private during this test."
# Sixty seconds of mono Layer III audio: a quiet 0.1-second 440 Hz tone, then silence.
# This fixture tests explicit Stop. Hosted XCTest can spend >10 seconds resolving
# and tapping that button; six-second audio had already ended before its tap event.
# Tests stop playback as soon as it starts and do not wait for the full duration.
# Generated from synthetic PCM at 22,050 Hz / 32 kbit/s. Embedded so hosted UI tests
# need only Python's standard library; these are complete, decodable MP3 frames.
SPEECH_MP3 = zlib.decompress(base64.b64decode("""
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
dIKAjtf7JNDxev8HIZd/Xg==
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
        reply = "Tool reply: " + source["snippet"] + "\n\nSource: " + source["day"] + "."
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
