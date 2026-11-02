"""Exercise the shipping MainActor chat session with a file-backed notebook on macOS."""
import argparse
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--build-path", type=pathlib.Path, default=ROOT / "DayPageCore/.build")
args = parser.parse_args()
build = args.build_path.resolve()
modules = next(build.glob("*/debug/Modules"))
objects = list(modules.parent.glob("DayPageCore.build/*.swift.o"))
assert objects, "Run swift test --package-path DayPageCore first"
with tempfile.TemporaryDirectory(prefix="daypage-chat-session-") as temporary:
    binary = pathlib.Path(temporary) / "chat-session-checks"
    subprocess.run([
        "swiftc", "-parse-as-library", "-I", str(modules),
        str(ROOT / "DayPageLocal/ChatSession.swift"),
        str(ROOT / "scripts/tests/fixtures/chat_session_recovery.swift"),
        *map(str, objects), "-o", str(binary),
    ], check=True)
    server = subprocess.Popen([sys.executable, "-u", str(ROOT / "scripts/tests/fixtures/chat_stream_server.py")], stdout=subprocess.PIPE, text=True)
    try:
        port = server.stdout.readline().strip()
        assert port.isdigit(), "The isolated streaming fixture failed to start"
        subprocess.run([str(binary), port], check=True, timeout=30)
    finally:
        server.terminate()
        server.wait(timeout=5)
