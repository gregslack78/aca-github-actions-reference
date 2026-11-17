from pathlib import Path
import html
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE / "aca-reference" if (BASE / "aca-reference").is_dir() else BASE
OUT = ROOT / "assets"
OUT.mkdir(parents=True, exist_ok=True)
W, H = 1500, 880
# (id, x, y, w, h, title, fill, stroke)
groups = [
    ("github", 20, 100, 440, 510, "GITHUB | private repository", "#eef2ff", "#6366f1"),
    ("vnet", 500, 285, 940, 505, "AZURE | customer-owned private network", "#f0f9ff", "#0284c7"),
    ("runners", 520, 335, 540, 245, "RUNNERS | choose option A or B", "#ffffff", "#64748b"),
]
nodes = [
    ("repo", 45, 150, 390, 120, "1  Repository",
     ["App team's repo: app code + pipeline files", "Recommended: protect main with a ruleset",
      "Recommended: CODEOWNERS on pipeline files"], "#ffffff", "#6366f1"),
    ("workflows", 45, 300, 390, 150, "2  Workflows + environments",
     ["build environment: main only, publishes image", "production environment: main only + approval",
      "Each job gets a short-lived OIDC token", "Token subject = repository + environment"], "#ffffff", "#6366f1"),
    ("pr", 45, 480, 390, 100, "3  Pull request checks",
     ["GitHub-hosted runner, read-only token", "No Azure identity, no private network"], "#ffffff", "#6366f1"),
    ("platform", 20, 640, 440, 120, "Platform team provides",
     ["Existing ACR, ACA, VNets, DNS and egress", "Bootstraps Entra apps, RBAC and runners"], "#f8fafc", "#475569"),
    ("entra", 520, 100, 430, 150, "4  Microsoft Entra ID",
     ["Two app registrations: build and deploy", "One federated credential per environment",
      "Trusts issuer + audience + exact subject", "No client secret stored in GitHub"], "#f5f3ff", "#7c3aed"),
    ("rbac", 990, 100, 430, 150, "5  Azure RBAC",
     ["Build identity: push images to ACR", "Deploy identity: update the one ACA app",
      "No subscription-wide roles", "Sign-in and ARM use public HTTPS"], "#f5f3ff", "#7c3aed"),
    ("vmss", 540, 385, 240, 175, "6A  VMSS runners",
     ["15 build + 2 deploy VMs", "Docker on build VMs only", "Persistent; trusted code", "Fixed or scheduled capacity"],
     "#eff6ff", "#2563eb"),
    ("jobs", 800, 385, 240, 175, "6B  ACA Jobs runners",
     ["One ephemeral job per runner", "KEDA scales 0-15 / 0-2", "No Docker; builds go to 8", "PAT in Key Vault (bootstrap)"],
     "#fff7ed", "#ea580c"),
    ("acr", 1130, 335, 290, 130, "7  Existing ACR (private)",
     ["Private endpoint; public off", "Images referenced by digest", "App pull identity: pull only"],
     "#ecfdf5", "#059669"),
    ("tasks", 1130, 500, 290, 105, "8  ACR Tasks pool (B)",
     ["VNet-connected; preview feature", "Runs Docker builds for option B"], "#fff7ed", "#ea580c"),
    ("aca", 1130, 625, 290, 155, "9  Existing ACA (private)",
     ["Internal environment", "Stage new revision, no traffic", "Private smoke test, then promote",
      "Old revision kept for rollback"], "#ecfdf5", "#059669"),
    ("dns", 520, 610, 540, 110, "10  Private DNS + controlled egress",
     ["ACR, Key Vault and ACA names resolve privately", "Outbound HTTPS: GitHub, Entra, ARM, packages"],
     "#ffffff", "#64748b"),
]
# Explicit routes keep public/private and option A/B paths distinct.
edges = [
    ("oidc", "workflows", "entra", [(435, 375), (480, 375), (480, 175), (520, 175)], "OIDC trust", "#7c3aed", False),
    ("rbacedge", "entra", "rbac", [(950, 175), (990, 175)], "RBAC", "#7c3aed", False),
    ("queue", "workflows", "runners", [(435, 440), (520, 440)], "outbound poll", "#64748b", True),
    ("push", "runners", "acr", [(1060, 400), (1130, 400)], "push image", "#2563eb", False),
    ("remote", "runners", "tasks", [(1060, 540), (1130, 540)], "B: build", "#ea580c", True),
    ("taskpush", "tasks", "acr", [(1275, 500), (1275, 465)], "push", "#ea580c", True),
    ("pull", "acr", "aca", [(1420, 400), (1460, 400), (1460, 700), (1420, 700)], "managed identity pull", "#059669", False),
    ("deploy", "runners", "aca", [(1060, 565), (1095, 565), (1095, 700), (1130, 700)], "deploy + smoke test", "#7c3aed", False),
]


def check_fit(x, w, title, lines):
    # Conservative text-width estimates for the 17px bold heading and 14px body fonts.
    assert 9.8 * len(title) <= w - 28, f"heading too wide: {title}"
    for line in lines:
        assert 7.3 * len(line) <= w - 28, f"line too wide: {line}"


svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="title desc">',
       '<title id="title">GitHub Actions to private Azure Container Apps reference architecture</title>',
       '<desc id="desc">GitHub repository and environments, Entra OIDC federation, VMSS or ACA Jobs runner options, private ACR and ACA, DNS and egress.</desc>',
       '<defs><marker id="arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto-start-reverse"><path d="M0,0 L8,4 L0,8 Z" fill="context-stroke"/></marker></defs>',
       '<rect width="100%" height="100%" fill="white"/>',
       '<style>text{font-family:Segoe UI,Arial,sans-serif;fill:#0f172a}.title{font-size:27px;font-weight:700}.heading{font-size:17px;font-weight:700}.body{font-size:14px}.edge{font-size:12px;paint-order:stroke;stroke:white;stroke-width:5px;stroke-linejoin:round}</style>',
       '<text x="25" y="40" class="title">GitHub Actions to private Azure Container Apps</text>',
       '<text x="25" y="65" class="body">Reference design for the GitHub and Entra setup | not a deployed environment</text>']
mx = ET.Element("mxfile", host="app.diagrams.net", type="device")
diagram = ET.SubElement(mx, "diagram", name="Private ACA delivery", id="aca-reference")
model = ET.SubElement(diagram, "mxGraphModel", dx=str(W), dy=str(H), grid="1", gridSize="10",
                      page="1", pageScale="1", pageWidth=str(W), pageHeight=str(H))
root = ET.SubElement(model, "root")
ET.SubElement(root, "mxCell", id="0")
ET.SubElement(root, "mxCell", id="1", parent="0")


def mx_box(identifier, x, y, w, h, title, lines, fill, stroke, group=False):
    value = "<b>" + html.escape(title) + "</b>"
    if lines:
        value += "<br><br>" + "<br>".join(html.escape(line) for line in lines)
    style = f"rounded=1;whiteSpace=wrap;html=1;fillColor={fill};strokeColor={stroke};fontSize=14;align=left;verticalAlign=top;spacing=14;"
    if group:
        style += "dashed=1;"
    cell = ET.SubElement(root, "mxCell", id=identifier, value=value, style=style, vertex="1", parent="1")
    ET.SubElement(cell, "mxGeometry", x=str(x), y=str(y), width=str(w), height=str(h), **{"as": "geometry"})


for identifier, x, y, w, h, title, fill, stroke in groups:
    svg += [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{fill}" stroke="{stroke}" stroke-width="2" stroke-dasharray="7 4"/>',
            f'<text x="{x+16}" y="{y+28}" class="heading">{html.escape(title)}</text>']
    mx_box(identifier, x, y, w, h, title, [], fill, stroke, True)
for identifier, x, y, w, h, title, lines, fill, stroke in nodes:
    check_fit(x, w, title, lines)
    assert 53 + (len(lines) - 1) * 23 + 14 <= h, f"{identifier}: text taller than box"
    svg += [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{fill}" stroke="{stroke}" stroke-width="2"/>',
            f'<text x="{x+14}" y="{y+27}" class="heading">{html.escape(title)}</text>']
    for i, line in enumerate(lines):
        svg.append(f'<text x="{x+14}" y="{y+53+i*23}" class="body">{html.escape(line)}</text>')
    mx_box(identifier, x, y, w, h, title, lines, fill, stroke)
for identifier, source, target, points, label, color, dashed in edges:
    path = " ".join(f"{'M' if i == 0 else 'L'}{x},{y}" for i, (x, y) in enumerate(points))
    dash = ' stroke-dasharray="7 4"' if dashed else ""
    svg.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="2" marker-end="url(#arrow)"{dash}/>')
    # Put labels on the longest segment.
    segments = list(zip(points, points[1:]))
    a, b = max(segments, key=lambda pair: abs(pair[0][0]-pair[1][0])+abs(pair[0][1]-pair[1][1]))
    length = abs(a[0]-b[0]) + abs(a[1]-b[1])
    assert 6.4 * len(label) <= length + 20, f"edge label too long for its segment: {label}"
    x, y = (a[0]+b[0])/2, (a[1]+b[1])/2
    rotate = f' transform="rotate(-90 {x-8} {y})"' if a[0] == b[0] else ""
    svg.append(f'<text x="{x if not rotate else x-8}" y="{y-8 if not rotate else y}" text-anchor="middle" class="edge"{rotate}>{html.escape(label)}</text>')
    style = f"edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;strokeColor={color};fontSize=12;endArrow=block;"
    if dashed:
        style += "dashed=1;"
    cell = ET.SubElement(root, "mxCell", id=identifier, value=label, style=style, edge="1", parent="1",
                         source=source, target=target)
    geometry = ET.SubElement(cell, "mxGeometry", relative="1", **{"as": "geometry"})
    array = ET.SubElement(geometry, "Array", **{"as": "points"})
    for x, y in points[1:-1]:
        ET.SubElement(array, "mxPoint", x=str(x), y=str(y))
svg += [
    '<text x="25" y="820" class="heading">Legend</text>',
    '<text x="25" y="847" class="body">Purple: identity / management plane   |   Blue: option A (VMSS)   |   Orange dashed: option B (ACA Jobs + ACR Tasks)</text>',
    '<text x="25" y="872" class="body">Green: private registry / application   |   Gray dashed: supporting flow   |   No inbound GitHub webhook required</text>',
    '</svg>']
(OUT / "architecture.svg").write_text("\n".join(svg), encoding="utf-8")
ET.indent(mx)
ET.ElementTree(mx).write(OUT / "architecture.drawio", encoding="utf-8", xml_declaration=True)
print("Generated editable draw.io XML and SVG from the same diagram model.")
