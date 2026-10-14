import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("localizations", ROOT / "Scripts/verify-localizations.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LocalizationContractTests(unittest.TestCase):
    def setUp(self):
        root = ROOT / ".build/Temporary/localization-tests"
        root.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=root)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.catalog = self.root / "Localizable.xcstrings"
        self.document = {"sourceLanguage": "zh-Hans", "strings": {
            "结果 %@": {"comment": "Result message; argument 1 is the result detail.", "localizations": {
                language: {"stringUnit": {"state": "translated", "value": value}}
                for language, value in (("zh-Hans", "结果 %@"), ("en", "Result %@"))
            }}
        }}

    def write(self):
        self.catalog.write_text(json.dumps(self.document))

    def test_repository_catalog_is_complete(self):
        self.assertGreater(MODULE.verify(ROOT / "Resources/Localizable.xcstrings"), 0)

    def test_translator_context_is_required(self):
        for comment in (None, "", "   "):
            self.document["strings"]["结果 %@"]["comment"] = comment
            self.write()
            with self.assertRaisesRegex(ValueError, "translator context"):
                MODULE.verify(self.catalog)

    def test_native_export_empty_label_is_explicitly_non_translatable(self):
        self.document["strings"][""] = {"shouldTranslate": False}
        self.write()
        self.assertEqual(MODULE.verify(self.catalog), 1)
        self.document["strings"][""] = {}
        self.write()
        with self.assertRaisesRegex(ValueError, "empty UI label"):
            MODULE.verify(self.catalog)
        del self.document["strings"][""]
        self.document["strings"]["结果 %@"]["shouldTranslate"] = False
        self.write()
        with self.assertRaisesRegex(ValueError, "cannot bypass"):
            MODULE.verify(self.catalog)

    def test_semantic_key_uses_source_value_as_argument_contract(self):
        entry = self.document["strings"].pop("结果 %@")
        self.document["strings"]["operation.result"] = entry
        self.write()
        self.assertEqual(MODULE.verify(self.catalog), 1)
        entry["localizations"]["en"]["stringUnit"]["value"] = "Result %lld"
        self.write()
        with self.assertRaisesRegex(ValueError, "format placeholders"):
            MODULE.verify(self.catalog)

    def test_changed_swift_argument_type_cannot_hide_behind_a_stable_key(self):
        self.document["strings"]["operation.result"] = self.document["strings"].pop("结果 %@")
        self.write()
        emitted = self.root / "Build/Intermediates.noindex/target/Strings.stringsdata"
        emitted.parent.mkdir(parents=True)
        def write_value(value):
            emitted.write_text(json.dumps({"source": "Shared/Example.swift", "tables": {
                "Localizable": [{"key": "operation.result", "value": value}]
            }}))
        write_value("结果 %@")
        self.assertEqual(MODULE.verify(self.catalog, derived_data=self.root), 1)
        write_value("结果 %lld")
        with self.assertRaisesRegex(ValueError, "compiler format placeholders"):
            MODULE.verify(self.catalog, derived_data=self.root)

    def test_template_variable_tokens_cannot_be_translated_or_added(self):
        entry = self.document["strings"]["结果 %@"]
        entry["localizations"]["zh-Hans"]["stringUnit"]["value"] = "结果 %@ {{clipboard}}"
        for value in ("Result %@ {{剪贴板}}", "Result %@", "Result %@ {{clipboard}} {{date}}"):
            entry["localizations"]["en"]["stringUnit"]["value"] = value
            self.write()
            with self.assertRaisesRegex(ValueError, "template variable tokens"):
                MODULE.verify(self.catalog)
        entry["localizations"]["en"]["stringUnit"]["value"] = "{{clipboard}} Result %@"
        self.write()
        self.assertEqual(MODULE.verify(self.catalog), 1)

    def test_missing_translation_and_wrong_format_fail(self):
        for unit in ({"state": "new", "value": "Result %@"},
                     {"state": "translated", "value": "Result %lld"}):
            self.document["strings"]["结果 %@"]["localizations"]["en"]["stringUnit"] = unit
            self.write()
            with self.assertRaises(ValueError):
                MODULE.verify(self.catalog)

    def test_new_compiler_key_cannot_silently_fall_back_to_chinese(self):
        self.write()
        emitted = self.root / "Build/Intermediates.noindex/target/Strings.stringsdata"
        emitted.parent.mkdir(parents=True)
        emitted.write_text(json.dumps({"source": "Shared/Example.swift", "tables": {
            "Localizable": [{"key": "尚未翻译"}]
        }}))
        with self.assertRaisesRegex(ValueError, "untranslated compiler keys"):
            MODULE.verify(self.catalog, derived_data=self.root)

    def test_extension_must_ship_the_same_translations_as_app(self):
        self.write()
        app = self.root / "QuickFile.app"
        for bundle in (app, app / "Contents/PlugIns/FinderExtension.appex"):
            for language in ("en", "zh-Hans"):
                path = bundle / f"Contents/Resources/{language}.lproj/Localizable.strings"
                path.parent.mkdir(parents=True)
                value = self.document["strings"]["结果 %@"]["localizations"][language]["stringUnit"]["value"]
                path.write_bytes(plistlib.dumps({"结果 %@": value}).decode("utf-8").encode("utf-16"))
        self.assertEqual(MODULE.verify(self.catalog, app=app), 1)
        path.write_bytes(plistlib.dumps({"结果 %@": "stale"}))
        with self.assertRaisesRegex(ValueError, "compiled translations differ"):
            MODULE.verify(self.catalog, app=app)

    def test_third_language_is_checked_without_changing_the_validator(self):
        self.document["strings"]["结果 %@"]["localizations"]["fr"] = {
            "stringUnit": {"state": "translated", "value": "Résultat %@"}}
        self.write()
        self.assertEqual(MODULE.verify(self.catalog, languages=["zh-Hans", "en", "fr"]), 1)
        with self.assertRaisesRegex(ValueError, "knownRegions"):
            MODULE.verify(self.catalog)
        self.document["strings"]["结果 %@"]["localizations"]["fr"]["stringUnit"]["state"] = "new"
        self.write()
        with self.assertRaises(ValueError):
            MODULE.verify(self.catalog, languages=["zh-Hans", "en", "fr"])

    def test_positional_reordering_checks_types_and_argument_identity(self):
        self.assertEqual(MODULE.format_arguments("%lld 个：%@"), MODULE.format_arguments("%2$@: %1$lld"))
        self.assertEqual(MODULE.format_arguments("100%% %@"), {1: "@"})
        self.assertNotEqual(MODULE.format_arguments("%lld %@"), MODULE.format_arguments("%1$@ %2$lld"))
        with self.assertRaises(ValueError):
            MODULE.format_arguments("%2$@ %lld")
        with self.assertRaises(ValueError):
            MODULE.format_arguments("%1$@ %1$lld")

    def test_plural_forms_require_other_and_preserve_arguments(self):
        self.document["strings"] = {"%lld 个文件": {"comment": "File count; argument 1 is the number of files.", "localizations": {
            "zh-Hans": {"stringUnit": {"state": "translated", "value": "%lld 个文件"}},
            "en": {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": "%lld file"}},
                "other": {"stringUnit": {"state": "translated", "value": "%lld files"}}
            }}}
        }}}
        self.write()
        self.assertEqual(MODULE.verify(self.catalog), 1)
        plural = self.document["strings"]["%lld 个文件"]["localizations"]["en"]["variations"]["plural"]
        plural["one"]["stringUnit"]["value"] = "%@ file"
        self.write()
        with self.assertRaisesRegex(ValueError, "format placeholders"):
            MODULE.verify(self.catalog)
        del plural["other"]
        self.write()
        with self.assertRaisesRegex(ValueError, "other"):
            MODULE.verify(self.catalog)

    @unittest.skipUnless(shutil.which("xcrun"), "requires Apple's catalog compiler")
    def test_plural_artifact_contract_compares_both_bundles(self):
        self.document["strings"]["%lld 个文件"] = {"comment": "File count; argument 1 is the number of files.", "localizations": {
            "zh-Hans": {"stringUnit": {"state": "translated", "value": "%lld 个文件"}},
            "en": {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": "%lld file"}},
                "other": {"stringUnit": {"state": "translated", "value": "%lld files"}}
            }}}
        }}
        self.document["version"] = "1.0"
        self.write()
        compiled = self.root / "compiled"
        compiled.mkdir()
        subprocess.run(["xcrun", "xcstringstool", "compile", str(self.catalog),
                        "--output-directory", str(compiled)], check=True, capture_output=True)
        app = self.root / "QuickFile.app"
        for bundle in (app, app / "Contents/PlugIns/FinderExtension.appex"):
            shutil.copytree(compiled, bundle / "Contents/Resources")
        self.assertEqual(MODULE.verify(self.catalog, app=app), 2)
        dictionary = next((app / "Contents/PlugIns/FinderExtension.appex").rglob("*.stringsdict"))
        dictionary.write_bytes(plistlib.dumps({}))
        with self.assertRaisesRegex(ValueError, "compiled plurals differ"):
            MODULE.verify(self.catalog, app=app)
