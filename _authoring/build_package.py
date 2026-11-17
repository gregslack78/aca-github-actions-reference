from pathlib import Path
from datetime import datetime, timezone
import json
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

import yaml

BASE = Path(__file__).resolve().parents[1]
PACKAGE = BASE / "aca-reference" if (BASE / "aca-reference").is_dir() else BASE
SAMPLES = PACKAGE / "samples"
if not __debug__:
    raise RuntimeError("Run without -O: package validation requires assertions.")
if PACKAGE != BASE:
    for source in (BASE / "_authoring").rglob("*"):
        if source.is_file() and "__pycache__" not in source.parts and source.suffix in {".py", ".txt", ".json", ".md"}:
            target = PACKAGE / source.relative_to(BASE)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
subprocess.run([sys.executable, "-B", str(BASE / "_authoring" / "render_workflows.py")], check=True)
template = (BASE / "_authoring" / "guide.template.md").read_text(encoding="utf-8")
guide = template
(PACKAGE / "README.md").write_text(guide, encoding="utf-8", newline="\n")
checks = []
TEXT_SUFFIXES = {".sh", ".yml", ".yaml", ".md", ".json", ".py", ".bicep", ".bicepparam", ".svg", ".drawio",
                 ".dockerignore", ".gitignore", ".gitattributes", ".example", ".txt"}


def package_files():
    for path in PACKAGE.rglob("*"):
        relative = path.relative_to(PACKAGE)
        if any(part in {".git", ".state", "__pycache__", ".venv", ".azure"} for part in relative.parts):
            continue
        if relative.parts[0] not in {"samples", "poc", "assets", "_authoring", ".github",
                                     "README.md", "validation.json", ".gitignore", ".gitattributes"}:
            continue
        if path.is_file() and path.name != "poc.env":
            yield path


def normalize_line_endings():
    """Windows editors write CRLF; shell scripts, Dockerfiles and cloud-init need LF."""
    changed = 0
    for path in package_files():
        if path.suffix in TEXT_SUFFIXES or path.name in {"Dockerfile", ".dockerignore", ".gitignore", ".gitattributes"}:
            data = path.read_bytes()
            fixed = data.replace(b"\r\n", b"\n")
            if fixed != data:
                path.write_bytes(fixed)
                changed += 1
    return changed


normalize_line_endings()


def record(name, detail):
    checks.append({"check": name, "status": "pass", "detail": detail})


workflows = sorted((SAMPLES / ".github" / "workflows").glob("*.yml")) + sorted(
    (PACKAGE / ".github" / "workflows").glob("*.yml"))
yaml_files = [path for path in package_files() if path.suffix in {".yml", ".yaml"}]
for path in yaml_files:
    data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    assert isinstance(data, dict), path
record("YAML parsing", f"{len(yaml_files)} YAML files, including {len(workflows)} workflows")
for path in workflows:
    data = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    assert "on" in data and "jobs" in data
    for action in re.findall(r"uses:\s*(\S+)", path.read_text()):
        assert re.fullmatch(r"[\w.-]+/[\w./-]+@[0-9a-f]{40}", action), action
record("Action pins", "Every external action uses a 40-character commit SHA")
ci = yaml.load((SAMPLES / ".github" / "workflows" / "ci.yml").read_text(), Loader=yaml.BaseLoader)
assert ci["jobs"]["test"]["runs-on"] == "ubuntu-24.04"
assert ci["permissions"] == {"contents": "read"}
record("Unprivileged PR workflow", "Hosted runner, read-only token, no OIDC permission")
release = yaml.load((SAMPLES / ".github" / "workflows" / "release.yml").read_text(), Loader=yaml.BaseLoader)
rollback = yaml.load((SAMPLES / ".github" / "workflows" / "rollback.yml").read_text(), Loader=yaml.BaseLoader)
assert release["jobs"]["build"]["environment"] == "build"
assert release["jobs"]["deploy"]["environment"] == "production"
assert release["jobs"]["deploy"]["concurrency"] == rollback["jobs"]["rollback"]["concurrency"]
record("Deployment boundaries", "Separate environments; shared release/rollback serialization group")
bash = shutil.which("bash")
if sys.platform == "win32":
    git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if git_bash.exists():
        bash = str(git_bash)
assert bash, "Bash is required to validate shell scripts."
shells = list(SAMPLES.rglob("*.sh"))
for path in shells:
    subprocess.run([str(bash), "-n", str(path)], check=True)
record("Shell syntax", f"bash -n passed for {len(shells)} shell scripts")
for workflow in workflows:
    data = yaml.load(workflow.read_text(), Loader=yaml.BaseLoader)
    for job in data["jobs"].values():
        for step in job.get("steps", []):
            if "run" in step and step.get("shell", "bash") == "bash":
                sanitized = re.sub(r"\$\{\{.*?\}\}", "placeholder", step["run"])
                subprocess.run([str(bash), "-n"], input=sanitized, text=True, check=True)
record("Inline workflow shell syntax", "All Bash run blocks parsed after expression substitution")
for path in (PACKAGE / "assets").glob("*"):
    ET.parse(path)
record("Diagram XML", "SVG and editable draw.io XML parse successfully")
for target in re.findall(r"\]\(([^)]+)\)", guide):
    if "://" in target or target.startswith("#"):
        continue
    destination = target.split("#")[0]
    if destination == "validation.json":
        continue
    assert PACKAGE.joinpath(*destination.split("/")).exists(), target
record("Markdown local links", "All local image and sample links resolve")
sample_files = {str(p.relative_to(SAMPLES)).replace("\\", "/")
                for p in SAMPLES.rglob("*") if p.is_file() and "__pycache__" not in p.parts}
linked = {t.split("#")[0].removeprefix("samples/").rstrip("/")
          for t in re.findall(r"\]\((samples/[^)]+)\)", guide)}
uncovered = {f for f in sample_files
             if not any(f == item or f.startswith(item + "/") for item in linked)}
assert not uncovered, uncovered
record("Sample coverage", f"All {len(sample_files)} sample files are linked from the guide")


def slug(heading):
    return re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")


def anchors(markdown):
    in_fence, found = False, set()
    for line in markdown.splitlines():
        if line.startswith("```"):
            in_fence = not in_fence
        elif not in_fence and re.match(r"#{1,6} ", line):
            found.add(slug(line.lstrip("#").strip()))
    return found


def check_markdown_links(path):
    text = path.read_text(encoding="utf-8")
    own = anchors(text)
    for target in re.findall(r"\]\(([^)\s]+)\)", text):
        if "://" in target:
            continue
        file_part, _, fragment = target.partition("#")
        destination = path if not file_part else (path.parent / file_part).resolve()
        assert destination.exists(), f"{path.name}: missing {target}"
        if fragment and destination.suffix == ".md":
            known = own if destination == path else anchors(destination.read_text(encoding="utf-8"))
            assert fragment in known, f"{path.name}: no heading for {target}"


POC = PACKAGE / "poc"
for doc in (PACKAGE / "README.md", POC / "POC.md", POC / "infra" / "README.md"):
    check_markdown_links(doc)
record("Markdown links and anchors", "Every local link and heading anchor in the guide, POC.md and infra/README.md resolves")

az_cli = shutil.which("az")
assert az_cli, "Azure CLI is required to compile the Bicep"
compiled = subprocess.run([az_cli, "bicep", "build", "--file", str(POC / "infra" / "main.bicep"), "--stdout"],
                          capture_output=True, text=True)
assert compiled.returncode == 0, compiled.stderr
diagnostics = [line for line in compiled.stderr.splitlines()
               if re.search(r"\b(Warning|Error)\b", line) and "new Bicep release" not in line]
assert not diagnostics, diagnostics
template_json = json.loads(compiled.stdout)
assert any(r.get("type") == "Microsoft.Compute/virtualMachineScaleSets" for r in template_json["resources"]) or \
    "runners" in json.dumps(template_json)
record("POC Bicep", "main.bicep and all modules compile with zero errors or analyzer warnings")
demo_compiled = subprocess.run(
    [az_cli, "bicep", "build", "--file", str(POC / "infra" / "public-demo.bicep"), "--stdout"],
    capture_output=True, text=True,
)
assert demo_compiled.returncode == 0, demo_compiled.stderr
assert not [line for line in demo_compiled.stderr.splitlines()
            if re.search(r"\b(Warning|Error)\b", line) and "new Bicep release" not in line], demo_compiled.stderr
demo_template = json.loads(demo_compiled.stdout)
assert demo_template["resources"], "Public demo template must contain resources"
record("Browser demo Bicep", "public-demo.bicep and its app module compile without analyzer warnings")
cloud_init = (POC / "infra" / "cloud-init" / "runner.yaml").read_text(encoding="utf-8")
rendered = yaml.safe_load(cloud_init.replace("@@PROVISION_B64@@", "QQ==").replace("@@MODE@@", "build"))
assert rendered["write_files"][0]["encoding"] == "b64" and rendered["runcmd"]
record("POC cloud-init", "runner.yaml parses as YAML after placeholder substitution")
poc_scripts = sorted((POC / "scripts").glob("*.sh"))
for path in poc_scripts:
    subprocess.run([str(bash), "-n", str(path)], check=True)
shellcheck = shutil.which("shellcheck")
if shellcheck:
    result = subprocess.run([shellcheck, "-x", "--severity=style", *[p.name for p in poc_scripts]],
                            cwd=POC / "scripts", capture_output=True, text=True)
    assert result.returncode == 0, result.stdout
    record("POC scripts", f"bash -n and ShellCheck (style severity) passed for {len(poc_scripts)} scripts")
else:
    record("POC scripts", f"bash -n passed for {len(poc_scripts)} scripts; ShellCheck was not installed")
placeholders = sorted(set(re.findall(r"<[A-Z][A-Z0-9_]*>", guide)))
record("Placeholder inventory", f"{len(placeholders)} named placeholders intentionally require customer values")
vmss_24x7 = round(17 * 730 * 0.086, 2)
vmss_business = round(17 * 220 * 0.086, 2)
aca_build = 1000 * 3600 * (0.000024 + 2 * 0.000003)
aca_deploy = 200 * 3600 * (0.5 * 0.000024 + 0.000003)
# The cost table in the guide is rounded from these values.
for figure in ("~$1,070", "~$320", "~$120", "~$11"):
    assert figure in guide, figure
assert "$7,900" not in guide and "proxy" not in guide.lower()
assert round(vmss_24x7, -1) == 1070 and round(vmss_business, -1) == 320
assert round(aca_build + aca_deploy, -1) == 120 and round(aca_deploy) == 11
record("Cost arithmetic", {
    "vmss_24x7": vmss_24x7,
    "vmss_business_hours": vmss_business,
    "aca_runners_before_grant": round(aca_build + aca_deploy, 2),
    "aca_deploy_only": round(aca_deploy, 2),
})
for label, directory in (("Application tests", SAMPLES / "app"),
                         ("Deployment automation regressions", BASE / "_authoring" / "tests")):
    result = subprocess.run([sys.executable, "-B", "-m", "unittest", "discover", "-s", str(directory), "-v"],
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    count = re.search(r"Ran (\d+) tests?", result.stderr)
    assert count, result.stderr
    record(label, f"{count.group(1)} tests passed in this build")
actionlint = shutil.which("actionlint")
if actionlint:
    subprocess.run([actionlint, "-shellcheck=", *[str(p) for p in workflows]], check=True)
    record("GitHub Actions semantic lint", f"actionlint passed all {len(workflows)} workflows")
report = {
    "scope": "Local artifact validation only; not a deployed reference environment",
    "validated_at_utc": datetime.now(timezone.utc).isoformat(),
    "python_version": sys.version.split()[0],
    "checks": checks,
    "not_run": (["actionlint (not installed)"] if not actionlint else []) + [
        "Visual browser inspection of diagrams",
        "Historical extra-validation.json is not imported as current evidence",
    ],
    "intentional_customer_placeholders": placeholders,
    "not_validated_live": [
        "Azure resources, network, DNS, roles and OIDC token exchange",
        "GitHub protection rules, real runner scaling, deployment and rollback",
        "ACA Job template acceptance in a live subscription",
        "Docker image build (performed separately by the hosted CI workflow)",
        "Dedicated ACR Tasks agent pool pricing: no figure is given in the guide",
    ],
}
(PACKAGE / "validation.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8", newline="\n")
normalize_line_endings()
archive = BASE / "aca-reference.zip"
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
    for path in sorted(package_files()):
        z.write(path, "aca-reference/" + path.relative_to(PACKAGE).as_posix())
with zipfile.ZipFile(archive) as z:
    assert "aca-reference/samples/.github/workflows/release.yml" in z.namelist()
    assert z.testzip() is None
    assert set(z.namelist()) == {"aca-reference/" + p.relative_to(PACKAGE).as_posix() for p in package_files()}
    for name in z.namelist():
        assert z.read(name) == PACKAGE.joinpath(*name.split("/")[1:]).read_bytes(), name
    with_cr = [n for n in z.namelist()
               if (Path(n).suffix in TEXT_SUFFIXES or Path(n).name == "Dockerfile") and b"\r" in z.read(n)]
    assert not with_cr, f"CR characters found in archive: {with_cr}"
print(json.dumps({"checks_passed": len(checks), "sample_files": len(sample_files),
                  "guide_lines": len(guide.splitlines()), "archive_bytes": archive.stat().st_size,
                  "archive": str(archive)}, indent=2))
