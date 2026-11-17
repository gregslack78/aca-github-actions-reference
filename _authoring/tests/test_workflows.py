import importlib.util
from pathlib import Path
import unittest


AUTHORING = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("render_workflows", AUTHORING / "render_workflows.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class WorkflowTests(unittest.TestCase):
    def test_root_workflows_use_samples_working_directory(self):
        for name in ("ci.yml", "release.yml", "rollback.yml"):
            with self.subTest(name=name):
                self.assertIn("working-directory: samples", renderer.render(name))

    def test_cloud_jobs_are_disabled_until_explicitly_enabled(self):
        for name in ("release.yml", "rollback.yml"):
            with self.subTest(name=name):
                self.assertIn("github.ref == 'refs/heads/main' && vars.DEPLOYMENT_ENABLED == 'true'",
                              renderer.render(name))

    def test_ci_runs_on_push_and_pull_request(self):
        text = renderer.render("ci.yml")
        self.assertIn("  push:\n    branches: [main]", text)
        self.assertIn("  pull_request:\n    branches: [main]", text)
        self.assertIn("working-directory: .\n        run: python3 -m unittest discover -s _authoring/tests -v", text)

    def test_artifact_path_is_relative_to_checkout_not_run_directory(self):
        self.assertIn("path: samples/release.json", renderer.render("release.yml"))

    def test_portable_templates_are_not_gated_or_relocated(self):
        sample = renderer.PACKAGE / "samples" / ".github" / "workflows" / "release.yml"
        text = sample.read_text(encoding="utf-8")
        self.assertNotIn("DEPLOYMENT_ENABLED", text)
        self.assertNotIn("working-directory: samples", text)
        self.assertIn("path: release.json", text)


if __name__ == "__main__":
    unittest.main()
