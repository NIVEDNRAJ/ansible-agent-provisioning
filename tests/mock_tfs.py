#!/usr/bin/env python3
"""A stand-in for the few Azure DevOps Server / TFS REST calls the role makes.

Used only by tests/test_server_check.yml. It is NOT a model of the real server: it
answers the two read-only endpoints the preflight asks about, in the shapes those
endpoints are documented to return, so the role's branches can be driven.

    python3 tests/mock_tfs.py 8099

Behaviour is chosen by the URL, so one process serves every case:

    /v4/...      ships agent 4.258.1      /v3/...     ships agent 3.246.0
    /nopkg/...   has no packages endpoint (404 there)
    anything else under another prefix: 404 everywhere (a wrong collection path)

Credentials (HTTP Basic, the PAT is the password):
    good-pat-SECRET-1       accepted
    forbidden-pat-SECRET-2  authenticated but not allowed (403)
    anything else           401

Pools: "Default" exists, every other name does not (count 0).
"""
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

GOOD = "good-pat-SECRET-1"
FORBIDDEN = "forbidden-pat-SECRET-2"
# What the packages/agent endpoint puts in "version". Azure DevOps Services answers with a
# string; an on-premises Azure DevOps Server / TFS answers with an object, which is what the
# first real run met ("'dict object' has no attribute 'split'"). /empty has no packages at all
# and /odd has a version that is neither, both of which must read as "the server did not say".
PREFIXES = {
    "/v4": "4.258.1",
    "/v3": "3.246.0",
    "/v3obj": {"major": 3, "minor": 246, "patch": 0},
    "/v4obj": {"major": 4, "minor": 258},
    "/empty": [],
    "/odd": {"text": "three"},
    "/nopkg": None,
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # keep test output quiet
        pass

    def reply(self, status, body=None):
        data = json.dumps(body if body is not None else {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        prefix = next((p for p in PREFIXES if url.path.startswith(p + "/")), None)
        if prefix is None:
            return self.reply(404, {"message": "no such path"})

        header = self.headers.get("Authorization", "")
        token = ""
        if header.startswith("Basic "):
            try:
                token = base64.b64decode(header[6:]).decode().split(":", 1)[1]
            except Exception:
                token = ""
        if token == FORBIDDEN:
            return self.reply(403, {"message": "TF400813: not authorized"})
        if token != GOOD:
            return self.reply(401, {"message": "TF400813: Resource not available for anonymous access"})

        route = url.path[len(prefix):]
        if route == "/_apis/distributedtask/pools":
            name = parse_qs(url.query).get("poolName", [""])[0]
            found = [{"id": 1, "name": name}] if name == "Default" else []
            return self.reply(200, {"count": len(found), "value": found})
        if route == "/_apis/distributedtask/packages/agent":
            version = PREFIXES[prefix]
            if version is None:
                return self.reply(404, {"message": "no packages endpoint"})
            if version == []:
                return self.reply(200, {"count": 0, "value": []})
            return self.reply(200, {"count": 1, "value": [{"version": version, "platform": "linux-x64"}]})
        return self.reply(404, {"message": "no such route"})


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
