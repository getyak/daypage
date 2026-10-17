#!/usr/bin/env python3
"""Replace only public Supabase fields in an existing, opaque release .env."""
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


class OverlayError(Exception):
    pass


def apply_overlay(path: Path, url: str, key: str) -> None:
    if not url or not key:
        raise OverlayError("both public configuration fields are required")
    if not re.fullmatch(r"https://[a-z]{20}\.supabase\.co", url):
        raise OverlayError("invalid hosted Supabase origin")
    if not re.fullmatch(r"sb_publishable_[A-Za-z0-9_-]{10,128}", key):
        raise OverlayError("only a public publishable key is accepted")
    temporary = None
    try:
        # Refuse symlinks and nonregular files before opening; O_NOFOLLOW closes
        # the symlink race. Atomic replacement also avoids truncating the input.
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise OverlayError("release environment must be a regular unlinked file")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as source:
            opened = os.fstat(source.fileno())
            if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                raise OverlayError("release environment changed during read")
            raw = source.read()
        prefixes = (b"SUPABASE_URL=", b"SUPABASE_PUBLISHABLE_KEY=", b"SUPABASE_ANON_KEY=")
        # Match the generator's LF-delimited parser, including CRLF. A bare CR
        # inside an opaque provider value must not become another config line.
        preserved = b"\n".join(line for line in raw.split(b"\n") if not line.startswith(prefixes))
        newline = b"\r\n" if b"\r\n" in raw else b"\n"
        if preserved and not preserved.endswith(b"\n"):
            preserved += newline
        result = preserved + b"SUPABASE_URL=" + url.encode("ascii") + newline
        result += b"SUPABASE_PUBLISHABLE_KEY=" + key.encode("ascii") + newline
        fd, temporary = tempfile.mkstemp(prefix=".daypage-release-env-", dir=path.parent)
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(result)
            output.flush()
            os.fsync(output.fileno())
        current = path.lstat()
        if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != (
                opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns):
            raise OverlayError("release environment changed before replacement")
        os.replace(temporary, path)
        temporary = None
    except OSError:
        # Never include exception text: an OS path or injected message can carry
        # values from the opaque configuration or caller environment.
        raise OverlayError("could not safely replace release environment") from None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def main() -> int:
    if len(sys.argv) != 2:
        print("[release-overlay] expected one environment-file path", file=sys.stderr)
        return 1
    try:
        url = os.environ.get("DAYPAGE_SUPABASE_URL", "")
        apply_overlay(Path(sys.argv[1]), url,
                      os.environ.get("DAYPAGE_SUPABASE_PUBLISHABLE_KEY", ""))
    except OverlayError as error:
        print(f"[release-overlay] {error}", file=sys.stderr)
        return 1
    print(f"[release-overlay] public backend configured: {url}; other fields preserved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
