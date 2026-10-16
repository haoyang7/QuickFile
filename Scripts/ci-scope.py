#!/usr/bin/env python3
"""Classify original Git objects; only a verified build increment avoids full CI."""

import os
from pathlib import Path
import re
import subprocess


SPEC = b"project.yml"
PROJECT = b"QuickFile.xcodeproj/project.pbxproj"
SHA = re.compile(r"[0-9a-f]{40}")
SPEC_VERSION = re.compile(rb'(?m)^(    CURRENT_PROJECT_VERSION: ")([1-9][0-9]*)(")$')
PROJECT_VERSION = re.compile(rb"(?m)^(\t{4}CURRENT_PROJECT_VERSION = )([1-9][0-9]*)(;)$")
SCALAR = rb'(?:"(?:[^"\\\r\n]|\\[^\r\n])*"|[A-Za-z0-9_.+-]+)'


def git(*args):
    # Replacement refs, textconv, attributes and working-tree edits cannot supply evidence.
    return subprocess.check_output(["git", "--no-replace-objects", *args], stderr=subprocess.PIPE)


def commit(sha):
    if not SHA.fullmatch(sha) or git("cat-file", "-t", sha) != b"commit\n":
        raise ValueError("scope endpoints must be full commit SHAs")
    return sha


def changed_objects(base, head):
    raw = git("diff", "--raw", "--no-abbrev", "--no-renames", "--no-ext-diff",
              "--no-textconv", "-z", base, head, "--")
    if not raw:
        return {}
    fields = raw.split(b"\0")
    if fields.pop() != b"" or len(fields) % 2:
        raise ValueError("invalid raw Git diff")
    changes = {}
    for header, path in zip(fields[::2], fields[1::2]):
        match = re.fullmatch(rb":([0-7]{6}) ([0-7]{6}) ([0-9a-f]{40}) ([0-9a-f]{40}) ([AMDT])", header)
        if not match or not path or path in changes:
            raise ValueError("ambiguous raw Git diff")
        changes[path] = match.groups()
    return changes


def documentation(path):
    return path == b"LICENSE" or (b"/" not in path and path.endswith(b".md"))


def project_structure(data):
    """Scan actual OpenStep containers, retaining only root identity/object spans."""
    lexer = re.compile(rb'(?P<skip>\s+|//[^\r\n]*|/\*.*?\*/)|'
                       rb'(?P<string>"(?:[^"\\]|\\.)*")|'
                       rb'(?P<punct>[{}()=;,])|(?P<atom>[A-Za-z0-9_./$+-]+)', re.DOTALL)
    tokens = []
    offset = 0
    while offset < len(data):
        match = lexer.match(data, offset)
        if not match:
            raise ValueError("unsupported project token")
        if match.lastgroup != "skip":
            kind = match[0] if match.lastgroup == "punct" else match.lastgroup.encode()
            tokens.append((kind, match[0], match.start(), match.end()))
        offset = match.end()
    cursor = 0
    root = {}
    objects = {}
    configuration_lists = {}

    def at(kind):
        return cursor < len(tokens) and tokens[cursor][0] == kind

    def take(kind):
        nonlocal cursor
        if not at(kind):
            raise ValueError("unsupported project container syntax")
        token = tokens[cursor]
        cursor += 1
        return token

    def value(path):
        if at(b"atom") or at(b"string"):
            return take(tokens[cursor][0])
        if at(b"("):
            start = take(b"(")[2]
            while not at(b")"):
                value(path + (b"[]",))
                if not at(b","):
                    break
                take(b",")
            return b"array", None, start, take(b")")[3]
        start = take(b"{")[2]
        keys = set()
        while not at(b"}"):
            key = take(b"atom")[1]
            # Current generated dictionary keys are plain identifiers. In
            # particular, quoted/escaped spellings cannot alias an earlier key.
            if not re.fullmatch(rb"[A-Za-z0-9_]+", key) or key in keys:
                raise ValueError("project dictionary keys must be plain and unique")
            keys.add(key)
            take(b"=")
            item = value(path + (key,))
            take(b";")
            if not path:
                root[key] = item
            elif path == (b"objects",):
                if not re.fullmatch(rb"[0-9A-F]{24}", key) or item[0] != b"dictionary":
                    raise ValueError("objects must contain ordinary object dictionaries")
                objects[key] = item[2:]
            elif len(path) == 2 and path[0] == b"objects" and key == b"buildConfigurationList":
                if item[0] != b"atom" or not re.fullmatch(rb"[0-9A-F]{24}", item[1]):
                    raise ValueError("configuration list references must be plain object IDs")
                configuration_lists[path[1]] = item[1]
        return b"dictionary", None, start, take(b"}")[3]

    parsed = value(())
    if (cursor != len(tokens) or parsed[0] != b"dictionary" or
            set(root) != {b"archiveVersion", b"classes", b"objectVersion", b"objects", b"rootObject"} or
            root[b"objects"][0] != b"dictionary" or root[b"rootObject"][0] != b"atom" or
            root[b"rootObject"][1] not in objects):
        raise ValueError("unsupported project root or objects structure")
    root_identifier = root[b"rootObject"][1]
    configuration_list = configuration_lists.get(root_identifier)
    if configuration_list not in objects:
        raise ValueError("shared project must directly reference a configuration list")
    return root_identifier, objects, configuration_list


def version_snapshot(spec, project):
    """Accept only the current shared spec and project Debug/Release layout."""
    for data in (spec, project):
        data.decode("utf-8")
        if b"\0" in data:
            raise ValueError("binary version file")
    spec_matches = list(SPEC_VERSION.finditer(spec))
    project_matches = list(PROJECT_VERSION.finditer(project))
    if (len(spec_matches) != 1 or len(project_matches) != 2 or
            len(re.findall(rb"\bCURRENT_PROJECT_VERSION[\"']?\s*:", spec)) != 1 or
            len(re.findall(rb"\bCURRENT_PROJECT_VERSION[\"']?\s*=", project)) != 2):
        raise ValueError("version assignments must be unique and canonical")
    # Validate every top-level line rather than guessing equivalent YAML key
    # spellings. Quoted/explicit keys, directives, tags and document boundaries
    # are outside this controlled format and must use full CI.
    top_keys = set()
    for line in spec.splitlines():
        if not line.strip() or line.lstrip().startswith(b"#") or line.startswith(b" "):
            continue
        entry = re.fullmatch(rb"([A-Za-z_][A-Za-z0-9_]*):(?: " + SCALAR + rb")?", line)
        if not entry or entry[1] in top_keys:
            raise ValueError("spec top-level keys must be plain and unique")
        top_keys.add(entry[1])
    # Consume the whole shared mapping through its top-level boundary. Only the
    # current flat scalar base is supported; duplicate/quoted bases, flow maps,
    # block scalars and nested settings fall back to full CI.
    settings = re.search(rb"(?m)^settings:\n  base:\n(?:    [A-Z][A-Z0-9_]*: " + SCALAR +
                         rb"\n)+\n*(?=^[A-Za-z_][A-Za-z0-9_]*:|\Z)", spec)
    if (not settings or
            not (settings.start() <= spec_matches[0].start() < settings.end())):
        raise ValueError("spec version must be shared")

    # Follow the PBXProject's actual shared configuration list, not target settings
    # or assignment-looking text in a comment. Current generated comments all end
    # on the same line; reject multiline/unclosed comments anywhere in the file.
    uncommented = re.sub(rb"/\*[^\r\n]*?\*/", b"", project)
    if b"/*" in uncommented or b"*/" in uncommented:
        raise ValueError("multiline or ambiguous project comments require full CI")
    root_identifier, objects, shared_list = project_structure(project)
    root = re.search(rb"(?m)^\t\t" + root_identifier + rb" /\* Project object \*/ = (?P<object>\{\n"
                     rb"\t{3}isa = PBXProject;\n(?:\t{3}[^\n]*\n)*\t\t\});$", project)
    if not root or root.span("object") != objects[root_identifier]:
        raise ValueError("root must identify the shared project")
    lists = re.findall(rb'^\t{3}buildConfigurationList = ([0-9A-F]{24}) /\* Build configuration list for PBXProject "QuickFile" \*/;', root[0], re.MULTILINE)
    if lists != [shared_list]:
        raise ValueError("shared project configuration list must be unique")
    configuration_list = re.search(
        rb"(?m)^\t\t" + lists[0] + rb" /\*[^\n]*\*/ = (?P<opening>\{)\n"
        rb"\t{3}isa = XCConfigurationList;\n\t{3}buildConfigurations = \(\n"
        rb"\t{4}(?P<debug>[0-9A-F]{24}) /\* Debug \*/,\n"
        rb"\t{4}(?P<release>[0-9A-F]{24}) /\* Release \*/,\n\t{3}\);", project)
    list_span = objects.get(lists[0], (-1, -1))
    if (not configuration_list or configuration_list.start("opening") != list_span[0] or
            configuration_list.end() > list_span[1]):
        raise ValueError("shared Debug/Release configurations are required")
    for identifier, name in zip((configuration_list["debug"], configuration_list["release"]), (b"Debug", b"Release")):
        configuration = re.search(
            rb"(?m)^\t\t" + identifier + rb" /\* " + name + rb" \*/ = (?P<object>\{\n"
            rb"\t{3}isa = XCBuildConfiguration;\n\t{3}buildSettings = \{\n"
            rb"(?P<settings>(?:\t{4}[^\n]*\n)*)\t{3}\};\n"
            rb"\t{3}name = " + name + rb";\n\t\t\});$", project)
        if (not configuration or configuration.span("object") != objects.get(identifier) or
                len(PROJECT_VERSION.findall(configuration["settings"])) != 1):
            raise ValueError("version must belong to each shared configuration")
        # Only flat scalar assignments and the generated scalar arrays are valid
        # here. Braces, multiline strings or comments could change the key's level.
        if not re.fullmatch(rb"(?:\t{4}[A-Z][A-Z0-9_]* = (?:" + SCALAR + rb";\n|\(\n"
                            rb"(?:\t{5}" + SCALAR + rb",\n)*\t{4}\);\n))+", configuration["settings"]):
            raise ValueError("shared project settings must use the controlled flat layout")
    values = [match[2] for match in spec_matches + project_matches]
    if len(set(values)) != 1:
        raise ValueError("spec and both project versions must agree")
    mask = lambda match: match[1] + b"<build>" + match[3]
    return values[0], SPEC_VERSION.sub(mask, spec), PROJECT_VERSION.sub(mask, project)


def classify(event, pr_base="", pr_head="", push_before="", push_head=""):
    if event == "workflow_dispatch" or event not in ("pull_request", "push"):
        return "full", "Full Linux and macOS validation required."
    if event == "pull_request":
        head = commit(pr_head)
        bases = git("merge-base", "--all", commit(pr_base), head).decode("ascii").splitlines()
        if len(bases) != 1:
            raise ValueError("PR must have one unambiguous merge base")
        base = commit(bases[0])
    else:
        if push_before == "0" * 40:
            return "full", "New branch push requires full Linux and macOS validation."
        base, head = commit(push_before), commit(push_head)
    changes = changed_objects(base, head)
    endpoints = f"Compared original commits `{base}` → `{head}`. "
    if changes and all(documentation(path) for path in changes):
        return "documentation", endpoints + "Only root Markdown/LICENSE changes; Linux and macOS tests are skipped, not tested."
    if {path for path in changes if not documentation(path)} != {SPEC, PROJECT}:
        return "full", endpoints + "Full Linux and macOS validation required."
    snapshots = [[], []]
    for path in (SPEC, PROJECT):
        old_mode, new_mode, old_object, new_object, status = changes[path]
        if old_mode != b"100644" or new_mode != old_mode or status != b"M":
            return "full", endpoints + "Version files must remain ordinary files with unchanged modes."
        for snapshot, object_id in zip(snapshots, (old_object, new_object)):
            snapshot.append(git("cat-file", "blob", object_id.decode("ascii")))
    try:
        before, after = (version_snapshot(*snapshot) for snapshot in snapshots)
    except (ValueError, UnicodeError):
        return "full", endpoints + "Version layout or consistency requires full validation."
    # Compare canonical decimal strings without an integer-size limit.
    increasing = (len(after[0]), after[0]) > (len(before[0]), before[0])
    if not increasing or before[1:] != after[1:]:
        return "full", endpoints + "Changes exceed a consistent, increasing internal build number."
    return "build-version", (endpoints + f"Verified shared internal build `{before[0].decode()}` → "
                             f"`{after[0].decode()}` in project.yml and both shared Debug/Release settings; "
                             "all other version-file bytes and modes are unchanged, with only optional root Markdown/LICENSE changes. "
                             "Linux and macOS tests are skipped, not tested; native, signing and DMG validation are not claimed.")


def main():
    scope, summary = classify(os.environ["GITHUB_EVENT_NAME"],
                              os.environ.get("PR_BASE_SHA", ""), os.environ.get("PR_HEAD_SHA", ""),
                              os.environ.get("PUSH_BEFORE_SHA", ""), os.environ.get("PUSH_HEAD_SHA", ""))
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"scope={scope}\nrun_checks={str(scope == 'full').lower()}\n")
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
        output.write(f"### Verification scope\n\n{summary}\n")


if __name__ == "__main__":
    main()
