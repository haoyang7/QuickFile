#!/usr/bin/env python3
"""Check QuickFile's explicit Shared source ownership and library dependency direction.

This reads the repository's block-style XcodeGen target lists, not general YAML.
Changes to that format must update this guard rather than silently bypass it.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


LIBRARIES = {
    "QuickFileCore": set(),
    "QuickFileInfrastructure": {"QuickFileCore"},
    "QuickFileApplication": {"QuickFileCore"},
}
FORBIDDEN_IMPORTS = {"SwiftUI", "Sparkle"}
IDENTIFIER = r"(?:[A-Za-z_][A-Za-z_0-9]*|`[A-Za-z_][A-Za-z_0-9]*`)"
STRING_OPENING = re.compile(r'(#{0,})("""|")')
TARGET_FIELDS = {
    "type", "platform", "deploymentTarget", "sources", "settings", "dependencies",
    "info", "entitlements", "postBuildScripts", "scheme",
}


def scalar(value: str) -> str:
    """Accept plain or quoted repository paths/names, without YAML expressions."""
    value = value.strip()
    if value.startswith(('"', "'")) and value.endswith(value[0]):
        value = value[1:-1]
    if not re.fullmatch(r"[A-Za-z_0-9./-]+", value):
        raise ValueError("unsupported path or dependency syntax in project.yml")
    return value


def target_sections(spec: str) -> dict[str, str]:
    top_level_keys = set()
    for line in spec.splitlines():
        if not line.strip() or line.lstrip().startswith("#") or line[0].isspace():
            continue
        key = re.match(r"([A-Za-z_][A-Za-z_0-9]*):", line)
        if not key:
            raise ValueError("unsupported top-level key syntax; use unquotedName: without spaces before the colon")
        top_level_keys.add(key[1])
    if top_level_keys & {"include", "targetTemplates"}:
        raise ValueError("architecture guard requires targets without includes or target templates")
    sections = spec.split("\ntargets:\n")
    if len(sections) != 2:
        raise ValueError("expected one block-style targets section in project.yml")
    body = re.split(r"^[A-Za-z_][A-Za-z_0-9]*:", sections[1], maxsplit=1, flags=re.MULTILINE)[0]
    if "\t" in body:
        raise ValueError("target indentation must use spaces")
    for line in body.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.match(r"^\S", line):
            raise ValueError("unsupported top-level syntax after targets")
        if re.match(r"^  \S", line) and not re.fullmatch(r"  [A-Za-z_][A-Za-z_0-9]*:", line):
            raise ValueError("unsupported target definition; use an unquoted name and two-space indentation")
        if re.match(r"^    \S", line):
            field = re.match(r"    ([A-Za-z_][A-Za-z_0-9]*):", line)
            if not field or field[1] not in TARGET_FIELDS:
                raise ValueError("unsupported target field or target indentation")
        if re.match(r"^(?: |   )\S", line):
            raise ValueError("target definitions require two-space indentation")
    matches = list(re.finditer(r"^  ([A-Za-z_][A-Za-z_0-9]*):$", body, re.MULTILINE))
    targets = {}
    for index, match in enumerate(matches):
        name = match[1]
        if name in targets:
            raise ValueError(f"duplicate target {name}")
        end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
        targets[name] = body[match.end():end]
    if not targets:
        raise ValueError("expected block-style target definitions")
    return targets


def target_list(section: str, key: str) -> list[str]:
    declarations = list(re.finditer(rf"^    {key}:(.*)$", section, re.MULTILINE))
    if not declarations:
        return []
    if len(declarations) != 1 or declarations[0][1].strip():
        raise ValueError(f"expected one block-style {key} list")
    tail = section[declarations[0].end():]
    body = re.split(r"^    [A-Za-z_][A-Za-z_0-9]*:", tail, maxsplit=1, flags=re.MULTILINE)[0]
    return [line for line in body.splitlines() if line.strip() and not line.lstrip().startswith("#")]


def source_paths(section: str, *, library: bool) -> list[str]:
    paths = []
    for line in target_list(section, "sources"):
        match = re.fullmatch(r"      - path: (.+)", line)
        if match:
            path = scalar(match[1])
            if any(part in ("", ".", "..") for part in path.split("/")):
                raise ValueError("source paths must use canonical repository-relative paths without aliases")
            paths.append(path)
        elif library or not line.startswith("        ") or re.search(r"\bpath:", line):
            raise ValueError("sources must use explicit '- path:' entries; Shared libraries allow no source filters")
    return paths


def swift_code(source: str) -> str:
    """Mask comments and Swift strings, preserving line numbers for import errors."""
    output = list(source)
    index = 0
    while index < len(source):
        start = index
        if source.startswith("//", index):
            index = source.find("\n", index)
            if index < 0:
                index = len(source)
        elif source.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise ValueError("unterminated Swift comment")
        else:
            opening = STRING_OPENING.match(source, index)
            if not opening:
                index += 1
                continue
            hashes, quotes = opening.groups()
            closing = quotes + hashes
            index += len(opening[0])
            while index < len(source):
                if source.startswith("\\" + hashes, index):
                    index += len(hashes) + 2
                elif source.startswith(closing, index):
                    index += len(closing)
                    break
                else:
                    index += 1
            else:
                raise ValueError("unterminated Swift string")
        for offset in range(start, index):
            if source[offset] != "\n":
                output[offset] = " "
    return "".join(output)


def imports(source: str) -> list[tuple[str, int]]:
    code = swift_code(source)
    result = []
    for keyword in re.finditer(r"\bimport\b", code):
        declaration = re.match(
            rf"\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?({IDENTIFIER})",
            code[keyword.end():],
        )
        line = code.count("\n", 0, keyword.start()) + 1
        if not declaration:
            raise ValueError(f"unsupported Swift import syntax at line {line}")
        result.append((declaration[1].strip("`"), line))
    return result


def verify_architecture(root: Path) -> list[str]:
    targets = target_sections((root / "project.yml").read_text())
    owners = {}
    for target, section in targets.items():
        library = target in LIBRARIES
        for path in source_paths(section, library=library):
            parts = Path(path).parts
            if library:
                if len(parts) < 2 or parts[0] != "Shared" or ".." in parts or not path.endswith(".swift"):
                    raise ValueError(f"{target} must list individual Shared Swift files: {path}")
                if not (root / path).is_file():
                    raise ValueError(f"{target} source does not exist: {path}")
                if path in owners:
                    raise ValueError(f"duplicate Shared source ownership: {path} ({owners[path]}, {target})")
                owners[path] = target
            elif (parts and parts[0] == "Shared") or (root / "Shared").is_relative_to((root / path).resolve()):
                raise ValueError(f"Shared sources may only compile in the three libraries: {target} lists {path}")
        if library:
            for line in target_list(section, "dependencies"):
                match = re.fullmatch(r"      - target: (.+)", line)
                if not match:
                    raise ValueError(f"{target} dependencies must use explicit '- target:' entries")
                dependency = scalar(match[1])
                if dependency not in LIBRARIES[target]:
                    raise ValueError(f"forbidden target dependency: {target} -> {dependency}")
    for library in LIBRARIES:
        if library not in targets:
            raise ValueError(f"missing library target: {library}")
    actual = {path.relative_to(root).as_posix() for path in (root / "Shared").rglob("*.swift")}
    missing = actual - owners.keys()
    if missing:
        raise ValueError("Shared Swift files missing from library targets: " + ", ".join(sorted(missing)))
    for path, target in owners.items():
        for module, line in imports((root / path).read_text()):
            local = module in targets or module.startswith("QuickFile") or module == "FinderExtension"
            if module in FORBIDDEN_IMPORTS or (local and module not in LIBRARIES[target]):
                raise ValueError(f"{path}:{line}: forbidden import {module} in {target}")
    return [f"{library}: {sum(owner == library for owner in owners.values())} Shared Swift files" for library in LIBRARIES]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    try:
        results = verify_architecture(args.root.resolve())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("\n".join(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
