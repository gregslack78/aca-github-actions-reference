import os
import unittest
from unittest.mock import patch

from server import response


class ResponseTests(unittest.TestCase):
    def test_message(self):
        self.assertEqual(response()["message"], "Hello from ACA")

    def test_commit(self):
        with patch.dict(os.environ, {"APP_COMMIT": "abc123"}):
            self.assertEqual(response()["commit"], "abc123")


if __name__ == "__main__":
    unittest.main()
