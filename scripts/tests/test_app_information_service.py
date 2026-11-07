"""Exercise the real private Nginx configuration over task-owned loopback HTTP.

Only deployment paths and the listen port are substituted. No system service,
container, cloud host, dependency installation or public listener is touched.
Local hosts without Nginx skip; CI requires the official Ubuntu Nginx package.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HOST = "daypage-api.cubxxw.com"
ROUTE = "/daypage/v1/app-info.json"


class PrivateAppInformationHTTP(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        nginx = shutil.which("nginx")
        if not nginx and Path("/usr/sbin/nginx").is_file():
            nginx = "/usr/sbin/nginx"
        if not nginx:
            if os.environ.get("APP_INFORMATION_REQUIRE_NGINX") == "1":
                raise RuntimeError("Nginx must be installed for this CI HTTP gate")
            raise unittest.SkipTest("Nginx is unavailable; no local installation is attempted")
        temporary = tempfile.TemporaryDirectory(prefix="daypage-information-http-")
        cls.addClassCleanup(temporary.cleanup)
        work = Path(temporary.name)
        work.chmod(0o755)  # Public fixture bytes remain readable by a worker if run as root.
        runtime = work / "runtime"
        runtime.mkdir()
        cls.payload = (ROOT / "DayPageLocal/Resources/app-info.json").read_bytes()
        payload_path = work / "app-info.json"
        payload_path.write_bytes(cls.payload)
        payload_path.chmod(0o644)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            cls.port = reservation.getsockname()[1]
        config = (ROOT / "deploy/app-information/nginx-private.conf").read_text()
        substitutions = {
            "/run/daypage-app-information": str(runtime),
            "/usr/share/daypage-app-information/app-info.json": str(payload_path),
            "127.0.0.1:18080": f"127.0.0.1:{cls.port}",
        }
        for original, replacement in substitutions.items():
            if original not in config:
                raise RuntimeError(f"Cannot isolate configuration path/port: {original}")
            config = config.replace(original, replacement)
        config_path = work / "nginx.conf"
        config_path.write_text(config)
        command = [nginx, "-p", str(work) + "/", "-c", str(config_path)]
        parsed = subprocess.run([*command, "-t"], capture_output=True, text=True, timeout=10)
        if parsed.returncode:
            raise RuntimeError("Nginx rejected the isolated actual configuration:\n" + parsed.stderr)
        log = (work / "nginx.log").open("w+")
        cls.addClassCleanup(log.close)
        process = subprocess.Popen([*command, "-g", "daemon off;"], stdout=log, stderr=log)

        def stop():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        cls.addClassCleanup(stop)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                log.seek(0)
                raise RuntimeError("Task-owned Nginx exited:\n" + log.read())
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.2):
                    return
            except OSError:
                time.sleep(0.02)
        raise RuntimeError("Task-owned Nginx did not become ready within five seconds")

    def request(self, *, method="GET", target=ROUTE, host=HOST, version="HTTP/1.1"):
        lines = [f"{method} {target} {version}", "Connection: close", "Content-Length: 0"]
        if host is not None:
            lines.append("Host: " + host)
        raw = ("\r\n".join(lines) + "\r\n\r\n").encode("ascii")
        with socket.create_connection(("127.0.0.1", self.port), timeout=3) as connection:
            connection.sendall(raw)
            with connection.makefile("rb") as response:
                status = int(response.readline(4096).split()[1])
                headers = {}
                for _ in range(64):
                    line = response.readline(4096)
                    if line in (b"\r\n", b"\n", b""):
                        break
                    name, value = line.decode("ascii").split(":", 1)
                    headers[name.lower()] = value.strip()
                body = response.read(131_073)
        return status, headers, body

    def test_exact_get_serves_reviewed_bundled_json_without_cache(self):
        status, headers, body = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(hashlib.sha256(body).digest(), hashlib.sha256(self.payload).digest())
        self.assertEqual(body, self.payload)
        self.assertEqual(json.loads(body)["appID"], "com.daypage.app")
        self.assertEqual(json.loads(body)["schemaVersion"], 1)
        self.assertEqual(headers.get("content-type"), "application/json")
        self.assertEqual(headers.get("cache-control"), "no-store")

    def test_unknown_paths_are_not_a_website_or_data_api(self):
        for path in ("/", "/other", "/notes", ROUTE + "/extra"):
            with self.subTest(path=path):
                self.assertEqual(self.request(target=path)[0], 404)

    def test_non_get_methods_are_refused(self):
        for method in ("HEAD", "POST", "PUT", "DELETE", "OPTIONS"):
            with self.subTest(method=method):
                self.assertEqual(self.request(method=method)[0], 405)

    def test_wrong_host_is_refused(self):
        self.assertEqual(self.request(host="other.invalid")[0], 404)

    def test_host_header_must_be_explicit_exact_lowercase_without_port(self):
        # The compiled HTTPS origin uses this exact lowercase, port-free Host.
        for host in (HOST.upper(), HOST + ":18080"):
            with self.subTest(host=host):
                self.assertEqual(self.request(host=host)[0], 404)

    def test_hostless_http10_cannot_use_server_name_fallback(self):
        self.assertEqual(self.request(host=None, version="HTTP/1.0")[0], 404)
        # A syntactically empty Host may be rejected by Nginx's parser first.
        self.assertIn(self.request(host="", version="HTTP/1.0")[0], (400, 404))

    def test_conflicting_absolute_target_does_not_override_host_restriction(self):
        self.assertEqual(self.request(target="http://other.invalid" + ROUTE)[0], 404)
        self.assertEqual(self.request(target="http://" + HOST + ROUTE, host="other.invalid")[0], 404)


if __name__ == "__main__":
    unittest.main()
