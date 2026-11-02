"""Exercise the shipping MainActor chat session with a file-backed notebook on macOS."""
import argparse
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
def run(build):
    build = build.resolve()
    modules = next(build.glob("*/debug/Modules"), None)
    if modules is None or not list(modules.parent.glob("DayPageCore.build/*.swift.o")):
        subprocess.run(["swift", "build", "--package-path", str(ROOT / "DayPageCore"),
                        "--scratch-path", str(build), "--jobs", "2"], check=True)
        modules = next(build.glob("*/debug/Modules"))
    objects = list(modules.parent.glob("DayPageCore.build/*.swift.o"))
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-path", type=pathlib.Path)
    args = parser.parse_args()
    if args.build_path:
        run(args.build_path)
    else:
        # Standalone script discovery does not build DayPageCore beforehand.
        # Keep that clean-start path independent of an existing developer build.
        with tempfile.TemporaryDirectory(prefix="daypage-chat-core-") as temporary:
            run(pathlib.Path(temporary))
