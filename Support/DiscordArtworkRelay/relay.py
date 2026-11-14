"""Temporary JPEG relay for iSyncer. Run behind an HTTPS reverse proxy."""

import hmac
import json
import os
import re
import secrets
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit

MAX_BYTES = 64 * 1024
MAX_IMAGES = 256
LIFETIME = 300
IMAGES = {}


class RelayServer(HTTPServer):
    def service_actions(self):
        now = time.monotonic()
        for path, (expiry, _) in list(IMAGES.items()):
            if expiry <= now:
                del IMAGES[path]


class Relay(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def log_message(self, *_):
        # The paths contain public access tokens.
        pass

    def respond(self, code, body=b"", media_type="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", media_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_POST(self):
        if self.path != "/covers":
            self.respond(404)
            return
        authorization = self.headers.get("Authorization", "").encode("utf-8")
        if not hmac.compare_digest(authorization, self.server.authorization):
            self.respond(401)
            return
        length = self.headers.get("Content-Length", "")
        if not re.fullmatch(r"[0-9]{1,5}", length) or not 4 <= int(length) <= MAX_BYTES:
            self.respond(413)
            return
        if self.headers.get_content_type() != "image/jpeg":
            self.respond(415)
            return
        data = self.rfile.read(int(length))
        if len(data) != int(length) or not (data.startswith(b"\xff\xd8\xff") and data.endswith(b"\xff\xd9")):
            self.respond(415)
            return
        now = time.monotonic()
        self.server.service_actions()
        if len(IMAGES) >= MAX_IMAGES:
            self.respond(503)
            return
        path = "/covers/" + secrets.token_urlsafe(24) + ".jpg"
        IMAGES[path] = (now + LIFETIME, data)
        body = json.dumps({"url": self.server.base_url + path, "expiresIn": LIFETIME}).encode()
        self.respond(201, body, "application/json")

    def do_GET(self):
        image = IMAGES.get(self.path)
        if image is None or image[0] <= time.monotonic():
            IMAGES.pop(self.path, None)
            self.respond(404)
            return
        self.respond(200, image[1], "image/jpeg")

    do_HEAD = do_GET


def main():
    token = os.environ.get("ISYNCER_RELAY_TOKEN", "")
    public_url = os.environ.get("ISYNCER_RELAY_URL", "").rstrip("/")
    url = urlsplit(public_url)
    if len(token) < 32 or url.scheme != "https" or not url.hostname or url.username or url.password or url.path or url.query or url.fragment:
        raise SystemExit("Set ISYNCER_RELAY_TOKEN and ISYNCER_RELAY_URL to a strong token and a public HTTPS origin.")
    with RelayServer(("127.0.0.1", int(os.environ.get("ISYNCER_RELAY_PORT", "8788"))), Relay) as server:
        server.authorization = ("Bearer " + token).encode()
        server.base_url = public_url
        server.serve_forever()


if __name__ == "__main__":
    main()
