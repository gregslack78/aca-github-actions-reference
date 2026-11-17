import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


BASE = Path(__file__).resolve().parents[2]
PACKAGE = BASE / "aca-reference" if (BASE / "aca-reference").is_dir() else BASE
BASH = str(Path(r"C:\Program Files\Git\bin\bash.exe")) if sys.platform == "win32" else shutil.which("bash")

AZ_MOCK = r"""#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CALLS"
case "$*" in
  "account set"*) ;;
  "account show"*) echo tenant ;;
  "group exists"*) echo "${MOCK_GROUP_EXISTS:-true}" ;;
  "group create"*) ;;
  "resource list"*) [[ "${MOCK_APP_EXISTS:-false}" != true ]] || echo app-id ;;
  "deployment group create"*|"deployment group what-if"*) ;;
  "deployment group show"*)
    case "$*" in
      *acaBootstrapRevision*) echo hello--bootstrap ;;
      *) echo example ;;
    esac ;;
  "containerapp revision show"*)
    if [[ "$*" == *"--query properties.healthState"* ]]; then echo Healthy
    else echo '{"properties":{"healthState":"Healthy","fqdn":"candidate.example"}}'; fi ;;
  "containerapp revision activate"*|"containerapp update"*) ;;
  "containerapp show"*) echo '{"properties":{"configuration":{"activeRevisionsMode":"Multiple","ingress":{"fqdn":"stable.example","traffic":[{"revisionName":"hello--old","weight":100}]}}}}' ;;
  "containerapp ingress traffic set"*) ;;
  "bicep version"*) echo bicep ;;
  "extension add"*) ;;
  "extension list"*) echo containerapp ;;
  "provider show"*) echo Registered ;;
  "rest"*) printf '%s\n' "$MOCK_SKU" ;;
  "vm list-usage"*) printf '%s\n' "$MOCK_USAGE" ;;
  "ad app list"*) echo "${MOCK_APPS:-[]}" ;;
  "ad app show"*) echo build-name ;;
  "ad app create"*) echo build-client ;;
  "ad sp list"*|"ad sp show"*) echo principal ;;
  "ad app federated-credential list"*) printf '%s\n' "${MOCK_FEDERATION:-null}" ;;
  "ad app federated-credential create"*) ;;
  "acr show"*) echo registry ;;
  "role assignment list"*) echo 1 ;;
  "retry-probe"*)
    if [[ ! -f "$RETRY_MARKER" ]]; then
      touch "$RETRY_MARKER"; echo partial-output; echo ConnectionReset >&2; exit 1
    fi
    echo complete-output ;;
  *) echo "Unexpected Azure mock call: $*" >&2; exit 91 ;;
esac
"""


class AutomationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.scripts = self.root / "poc" / "scripts"
        self.scripts.mkdir(parents=True)
        for source in (PACKAGE / "poc" / "scripts").glob("*.sh"):
            shutil.copyfile(source, self.scripts / source.name)
        self.sample_scripts = self.root / "scripts"
        self.sample_scripts.mkdir()
        for name in ("deploy.sh", "rollback.sh"):
            shutil.copyfile(PACKAGE / "samples" / "scripts" / name, self.sample_scripts / name)
        (self.sample_scripts / "smoke.sh").write_text(
            '#!/usr/bin/env bash\n'
            'echo "smoke $*" >> "$CALLS"\n'
            'if [[ "${MOCK_SMOKE_FAILURE:-}" == "$1" ]]; then exit 1; fi\n',
            encoding="utf-8", newline="\n",
        )
        self.write_mock("az", AZ_MOCK)
        self.write_mock("sleep", "#!/usr/bin/env bash\nexit 0\n")
        self.write_mock("curl", '#!/usr/bin/env bash\necho \'{"message":"Hello from ACA","commit":"abc123"}\'\n')
        self.write_mock("gh", '#!/usr/bin/env bash\ncase "$*" in\n'
                        '  "auth status"*) ;;\n'
                        '  *actions/oidc/customization/sub) printf \'%s\\n\' "$MOCK_OIDC_POLICY" ;;\n'
                        '  *) echo owner ;;\nesac\n')
        self.config = {
            "SUBSCRIPTION_ID": "subscription", "LOCATION": "eastus2", "RESOURCE_GROUP": "group",
            "POC_PREFIX": "test", "SSH_PUBLIC_KEY_FILE": (self.root / "key.pub").as_posix(),
            "VM_SIZE": "Standard_D4as_v5", "BUILD_INSTANCE_COUNT": "2", "DEPLOY_INSTANCE_COUNT": "1",
            "ACA_APP": "hello", "GH_OWNER": "owner", "GH_REPO": "reference", "GH_REVIEWER": "owner",
            "BUILD_APP_NAME": "build-name", "DEPLOY_APP_NAME": "deploy-name", "ACR_NAME": "registry",
            "TENANT_ID": "tenant",
        }
        (self.root / "key.pub").write_text("ssh-ed25519 test", encoding="utf-8")
        self.save_config()
        self.calls = self.root / "calls"
        self.env = {
            **os.environ,
            "MOCK_BIN": self.bin.as_posix(), "CALLS": self.calls.as_posix(),
            "RETRY_MARKER": (self.root / "retried").as_posix(),
            "ACA_APP": "hello", "ACA_RESOURCE_GROUP": "group", "REVISION": "hello--target",
            "ACR_LOGIN_SERVER": "registry.example", "IMAGE_REPOSITORY": "apps/hello",
            "IMAGE": "registry.example/apps/hello@sha256:" + "a" * 64,
            "GITHUB_SHA": "abc123", "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_STEP_SUMMARY": (self.root / "summary").as_posix(),
            "MOCK_SKU": json.dumps({"family": "testFamily", "restrictions": [],
                                   "capabilities": [{"name": "vCPUs", "value": "4"}]}),
            "MOCK_USAGE": json.dumps([{"name": {"value": name}, "limit": 16, "currentValue": 0}
                                     for name in ("testFamily", "cores")]),
            "MOCK_OIDC_POLICY": json.dumps({"use_default": True, "use_immutable_subject": True,
                                           "sub_claim_prefix": "repo:owner@123/reference@456"}),
        }

    def save_config(self):
        (self.root / "poc" / "poc.env").write_text(
            "\n".join(f'{key}="{value}"' for key, value in self.config.items()) + "\n",
            encoding="utf-8", newline="\n",
        )

    def write_mock(self, name, content):
        path = self.bin / name
        path.write_text(content, encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def run_script(self, script, *args, **environment):
        env = {**self.env, **environment, "SCRIPT": script}
        prefix = 'export PATH="$(cygpath -u "$MOCK_BIN"):$PATH"; ' if sys.platform == "win32" else 'export PATH="$MOCK_BIN:$PATH"; '
        return subprocess.run(
            [BASH, "-c", prefix + 'exec bash "$SCRIPT" "$@"', "--", *args],
            cwd=self.root, env=env, text=True, capture_output=True, timeout=30,
        )

    def read_calls(self):
        return self.calls.read_text(encoding="utf-8") if self.calls.exists() else ""

    def test_existing_app_is_not_redeployed_or_repinned(self):
        result = self.run_script("poc/scripts/01-deploy-infra.sh", MOCK_APP_EXISTS="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deployApp=false", self.read_calls())
        self.assertNotIn("containerapp ingress traffic set", self.read_calls())
        self.assertNotIn("containerapp revision show", self.read_calls())

    def test_new_app_is_bootstrapped(self):
        result = self.run_script("poc/scripts/01-deploy-infra.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deployApp=true", self.read_calls())
        self.assertIn("--revision-weight hello--bootstrap=100", self.read_calls())

    def test_what_if_never_creates_resource_group(self):
        result = self.run_script("poc/scripts/01-deploy-infra.sh", "--what-if")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("deployment group what-if", self.read_calls())
        self.assertNotIn("group create", self.read_calls())

    def test_what_if_missing_group_fails_without_writes(self):
        result = self.run_script("poc/scripts/01-deploy-infra.sh", "--what-if", MOCK_GROUP_EXISTS="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Create it explicitly first", result.stderr)
        self.assertNotIn("group create --name", self.read_calls())
        self.assertNotIn("deployment group", self.read_calls())

    def test_rollback_restores_previous_traffic_after_failed_stable_check(self):
        result = self.run_script("scripts/rollback.sh", MOCK_SMOKE_FAILURE="stable.example")
        self.assertNotEqual(result.returncode, 0)
        calls = self.read_calls()
        self.assertLess(calls.index("hello--target=100"), calls.index("hello--old=100"))
        self.assertIn("Traffic restored", result.stdout)

    def test_rollback_success_does_not_restore_old_traffic(self):
        result = self.run_script("scripts/rollback.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hello--target=100", self.read_calls())
        self.assertNotIn("hello--old=100", self.read_calls())

    def test_deploy_candidate_failure_does_not_promote(self):
        result = self.run_script("scripts/deploy.sh", MOCK_SMOKE_FAILURE="candidate.example")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("containerapp ingress traffic set", self.read_calls())

    def test_deploy_post_promotion_failure_restores_old_traffic(self):
        result = self.run_script("scripts/deploy.sh", MOCK_SMOKE_FAILURE="stable.example")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hello--gha123a1=100", self.read_calls())
        self.assertIn("hello--old=100", self.read_calls())

    def test_deploy_success(self):
        result = self.run_script("scripts/deploy.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hello--gha123a1=100", self.read_calls())
        self.assertNotIn("hello--old=100", self.read_calls())

    def test_quota_uses_actual_sku_vcpus(self):
        result = self.run_script("poc/scripts/00-check-prereqs.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("12 needed", result.stdout)

    def test_insufficient_regional_quota_fails(self):
        usage = json.dumps([{"name": {"value": name}, "limit": limit, "currentValue": 0}
                            for name, limit in (("testFamily", 16), ("cores", 8))])
        result = self.run_script("poc/scripts/00-check-prereqs.sh", MOCK_USAGE=usage)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Need 12 vCPUs for cores", result.stdout)

    def test_unknown_quota_is_not_reported_as_pass(self):
        result = self.run_script("poc/scripts/00-check-prereqs.sh", MOCK_USAGE="[]")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("capacity has not been verified", result.stdout)

    def test_ambiguous_app_names_are_rejected(self):
        result = self.run_script("poc/scripts/02-entra-and-roles.sh",
                                 MOCK_APPS='[{"appId":"one"},{"appId":"two"}]')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Multiple registrations", result.stderr)
        self.assertNotIn("ad app create", self.read_calls())

    def test_federation_drift_is_rejected(self):
        existing = json.dumps({"issuer": "https://token.actions.githubusercontent.com",
                               "subject": "repo:wrong/repo:environment:build",
                               "audiences": ["api://AzureADTokenExchange"]})
        result = self.run_script("poc/scripts/02-entra-and-roles.sh", MOCK_FEDERATION=existing)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("trusts different claims", result.stderr)
        self.assertNotIn("federated-credential create", self.read_calls())

    def test_federation_uses_github_reported_subject_prefix(self):
        for prefix in ("repo:owner@123/reference@456", "repo:owner/reference"):
            with self.subTest(prefix=prefix):
                (self.root / "poc" / ".state" / "outputs.env").unlink(missing_ok=True)
                result = self.run_script("poc/scripts/02-entra-and-roles.sh",
                                         MOCK_OIDC_POLICY=json.dumps(
                                             {"use_default": True, "sub_claim_prefix": prefix}))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for name, environment in (("github-build", "build"), ("github-production", "production")):
                    path = self.root / "poc" / ".state" / (name + ".json")
                    credential = json.loads(path.read_text(encoding="utf-8"))
                    self.assertEqual(credential["subject"], prefix + ":environment:" + environment)

    def test_missing_or_custom_oidc_policy_is_not_guessed(self):
        for policy in ({}, {"use_default": False, "sub_claim_prefix": "repo:owner/reference"}):
            with self.subTest(policy=policy):
                result = self.run_script("poc/scripts/02-entra-and-roles.sh",
                                         MOCK_OIDC_POLICY=json.dumps(policy))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Cannot determine the default OIDC subject prefix", result.stderr)
                self.assertNotIn("ad app create", self.read_calls())

    def test_teardown_requires_recorded_identity_ids(self):
        result = self.run_script("poc/scripts/99-teardown.sh", "--yes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BUILD_CLIENT_ID is not set", result.stderr)
        self.assertNotIn("delete", self.read_calls())

    def test_retry_discards_partial_output(self):
        probe = self.root / "probe.sh"
        probe.write_text('set -euo pipefail\nsource poc/scripts/lib.sh\naz retry-probe\n',
                         encoding="utf-8", newline="\n")
        result = self.run_script("probe.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "complete-output")
        self.assertIn("retrying", result.stderr)

    def test_runner_check_rejects_public_dns(self):
        self.write_mock("getent", '#!/usr/bin/env bash\necho "8.8.8.8 STREAM example"\n')
        self.write_mock("python3", '#!/usr/bin/env bash\nexec "$REAL_PYTHON" "$@"\n')
        self.write_mock("systemctl", '#!/usr/bin/env bash\nexit 0\n')
        result = self.run_script("poc/scripts/runner-check.remote.sh", "registry.example", "app.example",
                                 REAL_PYTHON=Path(sys.executable).as_posix())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CHECK_FAILED", result.stdout)
        self.assertNotIn("CHECK_OK", result.stdout)

    def test_runner_check_accepts_private_dns_and_successful_https(self):
        self.write_mock("getent", '#!/usr/bin/env bash\necho "10.60.1.4 STREAM example"\n')
        self.write_mock("python3", '#!/usr/bin/env bash\nexec "$REAL_PYTHON" "$@"\n')
        self.write_mock("systemctl", '#!/usr/bin/env bash\nexit 0\n')
        result = self.run_script("poc/scripts/runner-check.remote.sh", "registry.example", "app.example",
                                 REAL_PYTHON=Path(sys.executable).as_posix())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CHECK_OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
