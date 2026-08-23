"""Stand-in for a Coolify Deploy Webhook, used by the self-test.

  /deploy   -> 200, and the request line plus the Authorization header are
               appended to $STUB_LOG so the workflow can assert that force=true
               was added and the bearer token was sent.
  /health   -> 200, for waiting until the server is up.
  anything  -> 404 with a JSON body, the shape Coolify returns for a UUID it
               does not know.

Usage: python3 test/coolify-stub.py <host> <port> <logfile>
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def _record(self):
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(f"{self.command} {self.path} auth={self.headers.get('Authorization', '')}\n")

    def _respond(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            self._respond(200, {"ok": True})
            return
        self._record()
        if self.path.startswith("/deploy"):
            self._respond(200, {"message": "Deployment request queued."})
        else:
            self._respond(404, {"message": "Deployment not found."})

    do_POST = do_GET

    def log_message(self, *_args):
        pass  # the workflow reads $STUB_LOG; stderr noise only clutters the run


HTTPServer((HOST, PORT), Handler).serve_forever()
