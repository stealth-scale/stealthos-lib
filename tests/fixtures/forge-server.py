#!/usr/bin/env python3
"""A stand-in forge, for the tests of sys/net/forge.

Serves the paths named in a JSON map and answers 404 for everything else.

A static directory will not do here. GitLab puts the project in the path with
its slash written %2F, and http.server decodes that before it looks for a
file, so /api/v4/projects/g%2Fp/releases becomes a search for a directory
called p inside a directory called g. This reads the request path as it
arrived and looks it up unchanged.

Usage:
    forge-server.py PORT ROUTES.json
"""

import http.server
import json
import socketserver
import sys


def main() -> int:
    port = int(sys.argv[1])
    with open(sys.argv[2], encoding="utf-8") as handle:
        routes = json.load(handle)

    class Handler(http.server.BaseHTTPRequestHandler):
        """Answers from the map, and 404s anything that is not in it."""

        def do_GET(self) -> None:  # noqa: N802 - the name http.server wants
            body = routes.get(self.path)
            if body is None:
                self.send_error(404)
                return
            data = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_HEAD(self) -> None:  # noqa: N802 - the name http.server wants
            body = routes.get(self.path)
            if body is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body.encode("utf-8"))))
            self.end_headers()

        def log_message(self, *args: object) -> None:
            """Says nothing. The test's output is the test's own."""

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", port), Handler) as server:
        server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
