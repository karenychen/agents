#!/usr/bin/env python3
import http.client
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM_HOST = "litellm-copilot"
UPSTREAM_PORT = 4000
STRIP_KEY = "internal_chat_message_metadata_passthrough"


def strip_internal_metadata(value):
    if isinstance(value, dict):
        return {
            key: strip_internal_metadata(child)
            for key, child in value.items()
            if key != STRIP_KEY
        }
    if isinstance(value, list):
        return [strip_internal_metadata(child) for child in value]
    return value


def is_responses_path(path):
    path_without_query = path.split("?", 1)[0].rstrip("/")
    return path_without_query in {"/responses", "/v1/responses"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format, *_args):
        return

    def do_GET(self):
        self.forward()

    def do_POST(self):
        self.forward()

    def do_DELETE(self):
        self.forward()

    def do_PUT(self):
        self.forward()

    def do_PATCH(self):
        self.forward()

    def forward(self):
        body = self.rfile.read(int(self.headers.get("content-length", "0") or "0"))
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in {"host", "content-length", "connection"}
        }

        if body and is_responses_path(self.path):
            content_type = self.headers.get("content-type", "")
            if "application/json" in content_type:
                body = json.dumps(
                    strip_internal_metadata(json.loads(body)),
                    separators=(",", ":"),
                ).encode("utf-8")
                headers["content-type"] = "application/json"

        connection = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=600)
        try:
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            response_body = response.read()
        finally:
            connection.close()

        self.send_response(response.status, response.reason)
        for key, value in response.getheaders():
            if key.lower() not in {"connection", "transfer-encoding"}:
                self.send_header(key, value)
        self.send_header("content-length", str(len(response_body)))
        self.end_headers()
        self.wfile.write(response_body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 4000), Handler).serve_forever()
