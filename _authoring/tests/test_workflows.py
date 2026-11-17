import importlib.util
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

from test_automation import BASH


AUTHORING = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("render_workflows", AUTHORING / "render_workflows.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class WorkflowTests(unittest.TestCase):
    def test_committed_workflows_match_templates(self):
        for name in ("ci.yml", "release.yml", "rollback.yml"):
            with self.subTest(name=name):
                path = renderer.PACKAGE / ".github" / "workflows" / name
                self.assertEqual(path.read_text(encoding="utf-8"), renderer.render(name))

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

    def test_demo_release_is_opt_in_and_reuses_the_existing_build(self):
        text = renderer.render("release.yml")
        self.assertIn("if: vars.DEMO_DEPLOYMENT_ENABLED == 'true'", text)
        self.assertIn("ACA_APP: ${{ vars.DEMO_ACA_APP }}", text)
        self.assertLess(text.index("name: Stage, smoke test and promote"),
                        text.index("name: Deploy optional browser demo"))
        self.assertEqual(text.count("docker build --build-arg"), 1)

    def test_demo_rollback_never_silently_falls_back_to_private_app(self):
        text = renderer.render("rollback.yml")
        self.assertIn("default: private", text)
        block = next(block for block in re.split(r"^      - ", text, flags=re.MULTILINE)
                     if block.startswith("name: Select rollback target\n"))
        run = textwrap.dedent(re.search(
            r"^        run: \|\n((?:          [^\n]*\n)+)", block, re.MULTILINE).group(1))
        cases = (("private", "", "", 0), ("demo", "true", "hello-demo", 0),
                 ("demo", "", "hello-demo", 1), ("demo", "true", "", 1), ("invalid", "", "", 1))
        for target, enabled, app, code in cases:
            with self.subTest(target=target, enabled=enabled, app=app), tempfile.TemporaryDirectory() as temporary:
                env_file = Path(temporary) / "github-env"
                env = {**os.environ, "TARGET": target, "DEMO_ENABLED": enabled, "DEMO_APP": app,
                       "GITHUB_ENV": env_file.as_posix()}
                result = subprocess.run([BASH, "-s"], input=run, text=True, env=env,
                                        capture_output=True, timeout=10)
                self.assertEqual(result.returncode, code, result.stderr)
                if code == 0 and target == "demo":
                    self.assertEqual(env_file.read_text(), "ACA_APP=hello-demo\n")
                else:
                    self.assertFalse(env_file.exists())

    def test_portable_templates_are_not_gated_or_relocated(self):
        sample = renderer.PACKAGE / "samples" / ".github" / "workflows" / "release.yml"
        text = sample.read_text(encoding="utf-8")
        self.assertNotIn("vars.DEPLOYMENT_ENABLED", text)
        self.assertNotIn("working-directory: samples", text)
        self.assertIn("path: release.json", text)

    def test_credentials_can_be_created_and_removed_without_checkout(self):
        for name in ("release.yml", "rollback.yml"):
            blocks = re.split(r"^      - ", renderer.render(name), flags=re.MULTILINE)
            credential_steps = [block for block in blocks if block.startswith(
                ("name: Isolate per-job credentials\n", "name: Remove per-job credentials\n"))]
            self.assertEqual(len(credential_steps), 4 if name == "release.yml" else 2)
            for index in range(0, len(credential_steps), 2):
                with self.subTest(workflow=name, job=index // 2), tempfile.TemporaryDirectory() as temporary:
                    workspace = Path(temporary) / "workspace"
                    workspace.mkdir()
                    runner_temp = Path(temporary) / "runner-temp"
                    runner_temp.mkdir()
                    env_file = Path(temporary) / "github-env"
                    environment = {**os.environ, "RUNNER_TEMP": runner_temp.as_posix(),
                                   "GITHUB_ENV": env_file.as_posix()}
                    for step in credential_steps[index:index + 2]:
                        directory = re.search(r"^        working-directory: (.+)$", step, re.MULTILINE)
                        directory = directory.group(1) if directory else "samples"
                        cwd = runner_temp if directory == "${{ runner.temp }}" else workspace / directory
                        run = re.search(r"^        run: (.+)$", step, re.MULTILINE).group(1)
                        if run == "|":
                            run = textwrap.dedent(re.search(
                                r"^        run: \|\n((?:          [^\n]*\n)+)", step, re.MULTILINE).group(1))
                        result = subprocess.run([BASH, "-s"], input=run, text=True, cwd=cwd,
                                                env=environment, capture_output=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        if env_file.exists():
                            environment.update(line.split("=", 1) for line in
                                               env_file.read_text(encoding="utf-8").splitlines())
                    self.assertFalse((workspace / "samples").exists())
                    self.assertEqual(list(runner_temp.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
