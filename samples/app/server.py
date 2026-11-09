import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def response():
    return {"message": "Hello from ACA", "commit": os.environ.get("APP_COMMIT", "local")}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/health"):
            self.send_error(404)
            return
        body = json.dumps(response()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
