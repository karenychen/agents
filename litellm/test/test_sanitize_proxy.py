#!/usr/bin/env python3
import http.client
import importlib.util
import json
import socket
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "sanitize_proxy",
    ROOT / "ingress" / "sanitize_proxy.py",
)
sanitize_proxy = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(sanitize_proxy)


class CapturingUpstream(BaseHTTPRequestHandler):
    captured_body = b""

    def log_message(self, _format, *_args):
        return

    def do_POST(self):
        type(self).captured_body = self.rfile.read(
            int(self.headers.get("content-length", "0") or "0")
        )
        response = b'{"ok":true}'
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


class SanitizeProxyTest(unittest.TestCase):
    def setUp(self):
        self.upstream = ThreadingHTTPServer(("127.0.0.1", 0), CapturingUpstream)
        sanitize_proxy.UPSTREAM_HOST = "127.0.0.1"
        sanitize_proxy.UPSTREAM_PORT = self.upstream.server_port
        self.proxy = ThreadingHTTPServer(("127.0.0.1", 0), sanitize_proxy.Handler)
        self.threads = [
            threading.Thread(target=self.upstream.serve_forever, daemon=True),
            threading.Thread(target=self.proxy.serve_forever, daemon=True),
        ]
        for thread in self.threads:
            thread.start()

    def tearDown(self):
        self.proxy.shutdown()
        self.upstream.shutdown()
        self.proxy.server_close()
        self.upstream.server_close()

    def test_strips_codex_metadata_from_responses_path(self):
        body = {
            "model": "gpt-5.5",
            "input": [
                {
                    "role": "user",
                    "content": "hello",
                    "internal_chat_message_metadata_passthrough": {"thread": "abc"},
                }
            ],
        }
        conn = http.client.HTTPConnection("127.0.0.1", self.proxy.server_port)
        try:
            conn.request(
                "POST",
                "/responses",
                body=json.dumps(body),
                headers={"content-type": "application/json"},
            )
            self.assertEqual(conn.getresponse().status, 200)
        finally:
            conn.close()

        forwarded = json.loads(CapturingUpstream.captured_body)
        self.assertNotIn(
            "internal_chat_message_metadata_passthrough",
            json.dumps(forwarded),
        )

    def test_returns_gateway_error_when_upstream_is_unavailable(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            unused_port = sock.getsockname()[1]

        sanitize_proxy.UPSTREAM_HOST = "127.0.0.1"
        sanitize_proxy.UPSTREAM_PORT = unused_port
        proxy = ThreadingHTTPServer(("127.0.0.1", 0), sanitize_proxy.Handler)
        thread = threading.Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        conn = http.client.HTTPConnection("127.0.0.1", proxy.server_port)
        try:
            conn.request("GET", "/health/liveliness")
            response = conn.getresponse()
            self.assertEqual(response.status, 503)
            self.assertIn(b"upstream unavailable", response.read())
        finally:
            conn.close()
            proxy.shutdown()
            proxy.server_close()


if __name__ == "__main__":
    unittest.main()
