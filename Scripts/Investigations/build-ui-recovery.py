#!/usr/bin/env python3
"""Compile production models/views into a standalone, non-sandbox UI fixture on macOS."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--optimization", choices=("debug", "release"), default="debug")
    parser.add_argument("--modules-only", action="store_true")
    parser.add_argument("--probe", choices=("recovery", "tab-switch"), default="recovery")
    parser.add_argument("--row-accessibility", choices=("production", "combined-labels"), default="production",
                        help="Isolated experiment: combine only row name/summary, leaving Toggle independent")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    optimization = "-O" if args.optimization == "release" else "-Onone"
    spec = (ROOT / "project.yml").read_text()
    inputs = []
    for module in ("QuickFileCore", "QuickFileInfrastructure", "QuickFileApplication"):
        # Target sections contain indented fields; stop only at the next target name.
        section = re.split(r"\n  [A-Za-z][A-Za-z0-9]*:\n", spec.split(f"  {module}:\n", 1)[1], maxsplit=1)[0]
        sources = re.findall(r"- path: (Shared/[^\n]+)", section)
        inputs.extend(sources)
        command = ["xcrun", "swiftc", "-swift-version", "5", "-g", optimization, "-enable-testing",
                   "-emit-library", "-emit-module", "-module-name", module,
                   "-emit-module-path", str(out / f"{module}.swiftmodule"),
                   "-I", str(out), "-L", str(out), "-Xlinker", "-rpath", "-Xlinker", str(out)]
        if module != "QuickFileCore":
            command += ["-lQuickFileCore"]
        command += [str(ROOT / path) for path in sources]
        command += ["-o", str(out / f"lib{module}.dylib")]
        subprocess.run(command, check=True, cwd=ROOT)

    if args.modules_only:
        manifest = {"baseSHA": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                    "optimization": args.optimization,
                    "sources": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in inputs}}
        (out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return

    name = "UIRecovery" if args.probe == "recovery" else "TabSwitch"
    app = out / f"{name}.app"
    executable = app / f"Contents/MacOS/{name}"
    executable.parent.mkdir(parents=True, exist_ok=True)
    views = ["BackgroundWork", "AppModalPresentationGate", "FinderAuthorizationRequestPump", "QuickFileViewModel", "CreateFileView", "TemplateManagerView",
             "FinderMenuSettingsSection", "TemplateContentPreview",
             "TemplateEditorView", "TemplateEditorState", "TemplatePreviewController", "TemplateTransferPreviewView", "FinderMenuSettingsViewModel", "FinderIntegrationViewModel", "FinderIntegrationAdapter",
             "FinderExtensionDiagnostics", "AppKitFileActions",
             "AppTabsView", "DiagnosticsView", "DiagnosticsViewModel"]
    sources = [f"QuickFileApp/{name}.swift" for name in views] + [f"Scripts/Investigations/{name}.swift"]
    inputs += sources
    overrides = {}
    if args.row_accessibility == "combined-labels":
        path = "QuickFileApp/TemplateManagerView.swift"
        original = (ROOT / path).read_text()
        anchor = '''                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()'''
        if original.count(anchor) != 1:
            raise ValueError("Row experiment anchor changed; inspect production source before rebuilding")
        generated = out / "TemplateManagerView-combined-labels.swift"
        generated.write_text(original.replace(anchor, anchor.replace("            Spacer()", "            .accessibilityElement(children: .combine)\n            Spacer()")))
        overrides[path] = generated
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-g", optimization, "-parse-as-library",
                    "-I", str(out), "-L", str(out), "-lQuickFileCore", "-lQuickFileInfrastructure",
                    "-lQuickFileApplication", "-Xlinker", "-rpath", "-Xlinker", str(out),
                    *[str(overrides.get(path, ROOT / path)) for path in sources], "-o", str(executable)], check=True, cwd=ROOT)
    info = {"CFBundleIdentifier": "local.quickfile.investigation." + ("ui-recovery" if args.probe == "recovery" else args.probe),
            "CFBundleName": name, "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "NSHighResolutionCapable": True}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    manifest = {"baseSHA": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "scope": "standalone production UI/model fixture; non-sandbox; no App Group or real grants",
                "optimization": args.optimization,
                "rowAccessibility": args.row_accessibility,
                "generatedSourceOverrides": {path: {"path": str(generated), "sha256": hashlib.sha256(generated.read_bytes()).hexdigest()}
                                             for path, generated in overrides.items()},
                "sources": {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in inputs}}
    (out / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(executable)


if __name__ == "__main__":
    main()
