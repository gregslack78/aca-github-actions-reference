import http.client
import json
import os
import threading
import unittest
from unittest.mock import patch

from server import Handler, ThreadingHTTPServer, response, welcome_page


class ResponseTests(unittest.TestCase):
    def test_message(self):
        self.assertEqual(response()["message"], "Hello from ACA")

    def test_commit(self):
        with patch.dict(os.environ, {"APP_COMMIT": "abc123"}):
            self.assertEqual(response()["commit"], "abc123")

    def test_default_commit(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(response()["commit"], "local")

    def test_welcome_page_escapes_commit(self):
        with patch.dict(os.environ, {"APP_COMMIT": '<script>alert("test")</script>'}):
            page = welcome_page()
            self.assertNotIn("<script>", page)
            self.assertIn("&lt;script&gt;", page)


class HttpTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def test_routes_and_headers(self):
        with patch.dict(os.environ, {"APP_COMMIT": "http-test"}):
            for path in ("/", "/health"):
                with self.subTest(path=path):
                    connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
                    try:
                        connection.request("GET", path)
                        result = connection.getresponse()
                        body = result.read()
                        self.assertEqual(result.status, 200)
                        self.assertEqual(int(result.getheader("Content-Length")), len(body))
                        self.assertEqual(result.getheader("Cache-Control"), "no-store")
                        self.assertEqual(result.getheader("X-Content-Type-Options"), "nosniff")
                        self.assertIn("frame-ancestors 'none'", result.getheader("Content-Security-Policy"))
                        if path == "/health":
                            self.assertEqual(result.getheader("Content-Type"), "application/json")
                            self.assertEqual(json.loads(body), {"message": "Hello from ACA", "commit": "http-test"})
                        else:
                            self.assertEqual(result.getheader("Content-Type"), "text/html; charset=utf-8")
                            self.assertIn(b"<!doctype html>", body)
                            self.assertIn(b"Welcome aboard.", body)
                            self.assertIn(b"<code>http-test</code>", body)
                            self.assertIn(b'href="/health"', body)
                    finally:
                        connection.close()

    def test_unknown_route(self):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            connection.request("GET", "/unknown")
            result = connection.getresponse()
            self.assertEqual(result.status, 404)
            result.read()
        finally:
            connection.close()


if __name__ == "__main__":
    unittest.main()
