import json
import os
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def response():
    return {"message": "Hello from ACA", "commit": os.environ.get("APP_COMMIT", "local")}


def welcome_page():
    commit = escape(response()["commit"])
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Welcome | Azure Container Apps</title>
  <style>
    :root {{ color-scheme: light; font-family: system-ui, sans-serif; color: #17213b; }}
    body {{ margin: 0; min-height: 100vh; display: grid; place-items: center;
            background: linear-gradient(135deg, #eef2ff, #f0fdfa); }}
    main {{ margin: 2rem; padding: 3rem; max-width: 42rem; background: white;
            border: 1px solid #e6e6e6; border-radius: 1.5rem;
            box-shadow: 0 1rem 4rem #17213b12; }}
    .eyebrow {{ color: #464feb; font-weight: 700; letter-spacing: .12em; font-size: .8rem; }}
    h1 {{ font-size: clamp(2.5rem, 8vw, 4rem); line-height: 1.1; margin: 1rem 0; }}
    p {{ line-height: 1.7; }}
    code {{ display: block; overflow-wrap: anywhere; padding: 1rem; background: #f5f5f5;
            border-radius: .5rem; font-size: .85rem; }}
    a {{ color: #464feb; text-underline-offset: .2em; }}
    footer {{ margin-top: 2rem; font-size: .9rem; color: #526079; }}
  </style>
</head>
<body>
  <main>
    <span class="eyebrow">GITHUB ACTIONS + AZURE CONTAINER APPS</span>
    <h1>Welcome aboard.</h1>
    <p>Your hello world app is running. This page was packaged in a container
       and delivered through the release pipeline.</p>
    <p>Make a small change, open a pull request, and watch your next release arrive here.</p>
    <p>Look at my small change here.</p>
    <p>And another small change.</p>
    <p>And another small change. asdfasdfasdfasdfasdfasdfasdfasdfasdf</p>
    <p><strong>Release commit</strong></p>
    <code>{commit}</code>
    <footer><a href="/health">View application health</a></footer>
  </main>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/", "/health"):
            self.send_error(404)
            return
        is_health = self.path == "/health"
        body = (json.dumps(response()) if is_health else welcome_page()).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json" if is_health else "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; "
                         "base-uri 'none'; form-action 'none'")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
