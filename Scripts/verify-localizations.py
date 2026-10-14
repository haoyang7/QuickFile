#!/usr/bin/env python3
"""Validate translations, compiler-extracted keys and both shipped bundles."""
import argparse
import codecs
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
from xml.parsers.expat import ExpatError

ROOT = Path(__file__).resolve().parents[1]
FORMAT = re.compile(r"%(?:(?P<position>[1-9]\d*)\$)?[-+#0 ']*(?:\d+)?(?:\.\d+)?(?P<type>lld|llu|ld|lu|d|u|@|f|g|e)")


def configured_languages(project=ROOT / "project.yml"):
    match = re.search(r"^  knownRegions: \[(.+)\]$", project.read_text(), re.M)
    if not match:
        raise ValueError("project.yml must declare knownRegions as an inline list")
    languages = [value.strip() for value in match[1].split(",")]
    if len(languages) != len(set(languages)) or "zh-Hans" not in languages:
        raise ValueError("knownRegions must be unique and include the source language zh-Hans")
    return languages


def format_arguments(text):
    # Preserve argument position/type, allowing e.g. "%2$@ — %1$lld".
    # %% is literal; mixing positioned and sequential arguments is ambiguous.
    arguments = {}
    positions = set()
    next_position = 1
    for match in FORMAT.finditer(text.replace("%%", "")):
        explicit = match["position"] is not None
        positions.add(explicit)
        position = int(match["position"]) if explicit else next_position
        next_position += 1
        kind = match["type"]
        if position in arguments and arguments[position] != kind:
            raise ValueError("inconsistent types for a positional format argument")
        arguments[position] = kind
    if len(positions) > 1:
        raise ValueError("do not mix positional and sequential format arguments")
    return arguments


def translation_values(node):
    if "stringUnit" in node:
        unit = node["stringUnit"]
        if unit.get("state") != "translated" or not isinstance(unit.get("value"), str) or not unit["value"]:
            raise ValueError("translation must be nonempty and marked translated")
        return [unit["value"]]
    variations = node.get("variations", {})
    plural = variations.get("plural")
    if plural and set(variations) == {"plural"} and "other" in plural:
        if set(plural) - {"zero", "one", "two", "few", "many", "other"}:
            raise ValueError("unsupported plural category")
        return [value for branch in plural.values() for value in translation_values(branch)]
    raise ValueError("expected a stringUnit or plural variations with an other branch")


def read_strings(path):
    data = path.read_bytes()
    if data.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
        data = data.decode("utf-16").replace('encoding="UTF-16"', 'encoding="UTF-8"').encode("utf-8")
    return plistlib.loads(data)


def verify(catalog, derived_data=None, app=None, languages=None):
    document = json.loads(catalog.read_text())
    if document.get("sourceLanguage") != "zh-Hans":
        raise ValueError("catalog source language must be zh-Hans")
    strings = dict(document["strings"])
    # Xcode exports intentional empty UI labels as a catalog key. Keep the
    # native non-translatable marker so export/import does not recreate it.
    if "" in strings:
        empty = strings.pop("")
        if empty.get("shouldTranslate") is not False or empty.get("localizations"):
            raise ValueError("empty UI label must be marked non-translatable without translations")
    if not strings:
        raise ValueError("catalog is empty")
    languages = languages or configured_languages()
    present = {language for entry in strings.values() for language in entry.get("localizations", {})}
    if present != set(languages):
        raise ValueError(f"catalog languages {sorted(present)} differ from knownRegions {languages}")
    values = {language: {} for language in languages}
    has_plurals = False
    for key, entry in strings.items():
        if entry.get("shouldTranslate") is False:
            raise ValueError(f"product text cannot bypass translation: {key!r}")
        if not isinstance(entry.get("comment"), str) or not entry["comment"].strip():
            raise ValueError(f"missing translator context: {key!r}")
        # Semantic keys need not contain the source text or its placeholders.
        # The source-language value is the format contract for every translation.
        source_values = translation_values(entry.get("localizations", {}).get(document["sourceLanguage"], {}))
        source_arguments = format_arguments(source_values[0])
        source_tokens = set(re.findall(r"\{\{[^{}]+\}\}", source_values[0]))
        if any(format_arguments(value) != source_arguments for value in source_values):
            raise ValueError(f"source plural format placeholders differ: {key!r}")
        for language in values:
            node = entry.get("localizations", {}).get(language, {})
            try:
                translations = translation_values(node)
                for value in translations:
                    if source_arguments != format_arguments(value):
                        raise ValueError("format placeholders differ")
                    if source_tokens != set(re.findall(r"\{\{[^{}]+\}\}", value)):
                        raise ValueError("template variable tokens differ")
            except ValueError as error:
                raise ValueError(f"{language}: {key!r}: {error}") from error
            has_plurals |= "variations" in node
            if "stringUnit" in node:
                values[language][key] = translations[0]
    if derived_data:
        keys = set()
        emitted_values = []
        for path in derived_data.glob("Build/Intermediates.noindex/**/*.stringsdata"):
            extracted = json.loads(path.read_text())
            source = Path(extracted.get("source", ""))
            if source.parent.name not in ("QuickFileApp", "Shared", "FinderExtension"):
                continue
            for entry in extracted.get("tables", {}).get("Localizable", []):
                if entry["key"]:
                    keys.add(entry["key"])
                    emitted_values.append((entry["key"], entry.get("value", entry["key"])))
        if not keys:
            raise ValueError("no product localization keys were emitted by the compiler")
        missing = keys - strings.keys()
        if missing:
            raise ValueError(f"untranslated compiler keys: {sorted(missing)!r}")
        for key, value in emitted_values:
            source_value = translation_values(strings[key]["localizations"][document["sourceLanguage"]])[0]
            if format_arguments(value) != format_arguments(source_value):
                raise ValueError(f"compiler format placeholders differ from catalog source: {key!r}")
    if app:
        for bundle in (app, app / "Contents/PlugIns/FinderExtension.appex"):
            for language, expected in values.items():
                path = bundle / "Contents/Resources" / f"{language}.lproj/Localizable.strings"
                actual = read_strings(path) if expected else {}
                if any(actual.get(key) != value for key, value in expected.items()):
                    raise ValueError(f"compiled translations differ: {bundle.name}/{language}")
        if has_plurals:
            # Let Apple's catalog compiler define the .stringsdict representation.
            # Compare both products against that result, rather than implementing
            # a second plural compiler in this guard.
            temporary_root = ROOT / ".build/Temporary/localization-validation"
            temporary_root.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(dir=temporary_root) as temporary:
                subprocess.run(["xcrun", "xcstringstool", "compile", str(catalog),
                                "--output-directory", temporary], check=True, capture_output=True)
                for expected_path in Path(temporary).rglob("*.stringsdict"):
                    relative = expected_path.relative_to(temporary)
                    for bundle in (app, app / "Contents/PlugIns/FinderExtension.appex"):
                        actual = bundle / "Contents/Resources" / relative
                        if read_strings(actual) != read_strings(expected_path):
                            raise ValueError(f"compiled plurals differ: {bundle.name}/{relative}")
    return len(strings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=ROOT / "Resources/Localizable.xcstrings")
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        count = verify(args.catalog, args.derived_data, args.app)
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException, ExpatError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")
    print(f"Localization contract passed: {count} keys, {', '.join(configured_languages())}")


if __name__ == "__main__":
    main()
