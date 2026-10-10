"""Source guard for the production row's narrow callback capture contract.

These checks deliberately inspect Swift source, not compiler captures or live UI.
They do not establish SwiftUI/AppKit/AX deallocation, leaks, or memory recovery.
Native behavior tests and a signed-app recovery measurement remain separate.
New callback entry points require review and an explicit extension of this guard.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "QuickFileApp/TemplateManagerView.swift"


def capture_contract_violations(source):
    """Guard the known Binding, click, copy, drag and context-menu callbacks."""
    match = re.search(
        r"private func templateRow\(_ template: FileTemplate\) -> some View \{"
        r"(?P<row>.*?)\n    private func editSelected\(", source, re.DOTALL
    )
    if match is None:
        return ["row boundary changed; review the capture guard"]
    row = match["row"]
    violations = []

    # These locals are evaluated before any deferred row action is created.
    # A name snapshot is intentional: delete confirmation keeps the row label.
    preamble, separator, _ = row.partition("return HStack")
    preamble = re.sub(r"//[^\n]*", "", preamble)
    if not separator or re.sub(r"\s+", "", preamble) != (
        "letid=template.idletname=template.nameletisEnabled=template.isEnabled"
    ):
        violations.append("row snapshots must contain only ID, name, and Bool")

    getter = re.search(r"Binding\(get:\s*\{([^{}]*)\},\s*set:", row)
    if getter is None or getter[1].strip() != "isEnabled":
        violations.append("toggle getter must read the Bool snapshot")

    setter = re.search(r"set:\s*\{(.*?)\}\)\)\s*\.labelsHidden", row, re.DOTALL)
    if setter is None or not re.fullmatch(
        r"\s*enabled in\s*Task\s*\{\s*await viewModel\.setTemplateEnabled\(enabled, id: id\)\s*\}\s*",
        setter[1],
    ):
        violations.append("toggle setter must target the captured ID")

    _, separator, deferred = row.partition(".simultaneousGesture(")
    # Ignore the method name in viewModel.template(...) and the argument label
    # in TemplateEditorPresentation(template: current), not value references.
    if not separator or re.search(r"(?<![\w.])template\b(?!\s*:)", deferred):
        violations.append("deferred row actions must not reference the FileTemplate value")

    if not re.search(
        r"\.simultaneousGesture\(TapGesture\(\)\.onEnded\s*\{\s*"
        r"selectedTemplateID = id\s*\}\)", row
    ):
        violations.append("single-click must select the captured ID")

    edit_action = (
        r"\{\s*guard let current = viewModel\.template\(withID: id\) else \{ return \}\s*"
        r"selectedTemplateID = id\s*"
        r"editorPresentation = TemplateEditorPresentation\(template: current\)\s*\}"
    )
    for marker in (r"\.simultaneousGesture\(TapGesture\(count: 2\)\.onEnded", r'Button\("编辑"\)'):
        if not re.search(marker + r"\s*" + edit_action, row):
            violations.append("each edit action must look up the current template by ID")

    if not re.search(
        r'Button\("删除"\)\s*\{\s*confirmation = \.delete\(id, name\)\s*\}', deferred
    ):
        violations.append("delete must preserve the captured ID and displayed name")
    if not re.search(r"case delete\(FileTemplate\.ID, String\)", source):
        violations.append("delete confirmation must store only ID and name")
    if not re.search(r'Button\("复制"\)\s*\{\s*copyTemplate\(withID: id\)\s*\}', row):
        violations.append("copy callback must resolve by captured ID")
    if not re.search(r'\.onDrag\s*\{\s*beginReorder\(withID: id\)\s*\}', row):
        violations.append("drag callback must use only captured ID")
    if not re.search(
        r'TemplateRowDropDelegate\(\s*viewModel: viewModel, state: \$reorderState, targetID: id\s*\)', row
    ):
        violations.append("drop delegate must receive only the target ID")
    return violations


class TemplateRowCaptureContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_production_row_keeps_narrow_captures_and_fresh_edit_lookup(self):
        self.assertEqual(capture_contract_violations(self.source), [])

    def assert_rejected_mutation(self, before, after, expected):
        self.assertEqual(capture_contract_violations(self.source), [], "Baseline must pass before mutation")
        self.assertIn(before, self.source, "Mutation no longer exercises the production source")
        mutated = self.source.replace(before, after, 1)
        self.assertIn(expected, capture_contract_violations(mutated))

    def test_guard_rejects_original_whole_template_getter(self):
        self.assert_rejected_mutation(
            "get: { isEnabled }", "get: { template.isEnabled }",
            "toggle getter must read the Bool snapshot",
        )

    def test_guard_rejects_original_whole_template_delete_capture(self):
        self.assert_rejected_mutation(
            "confirmation = .delete(id, name)", "confirmation = .delete(id, template.name)",
            "deferred row actions must not reference the FileTemplate value",
        )

    def test_guard_rejects_whole_template_single_click_capture(self):
        self.assert_rejected_mutation(
            "TapGesture().onEnded { selectedTemplateID = id }",
            "TapGesture().onEnded { selectedTemplateID = template.id }",
            "deferred row actions must not reference the FileTemplate value",
        )

    def test_guard_rejects_wrong_single_click_selection(self):
        self.assert_rejected_mutation(
            "TapGesture().onEnded { selectedTemplateID = id }",
            "TapGesture().onEnded { selectedTemplateID = UUID() }",
            "single-click must select the captured ID",
        )

    def test_guard_rejects_missing_gesture_entry_points(self):
        for before, expected in (
            (".simultaneousGesture(TapGesture().onEnded", "single-click must select the captured ID"),
            (".simultaneousGesture(TapGesture(count: 2).onEnded", "each edit action must look up the current template by ID"),
        ):
            with self.subTest(before=before):
                self.assert_rejected_mutation(before, ".unreviewedGesture(", expected)

    def test_guard_rejects_whole_template_toggle_setter(self):
        self.assert_rejected_mutation(
            "setTemplateEnabled(enabled, id: id)", "setTemplateEnabled(enabled, id: template.id)",
            "toggle setter must target the captured ID",
        )

    def test_guard_rejects_stale_edit_snapshot_for_each_entry_point(self):
        self.assertEqual(capture_contract_violations(self.source), [])
        before = "guard let current = viewModel.template(withID: id) else { return }"
        self.assertEqual(self.source.count(before), 2)
        # Independently mutate double-click and context-menu editing.
        offsets = [match.start() for match in re.finditer(re.escape(before), self.source)]
        for offset in offsets:
            with self.subTest(offset=offset):
                mutated = self.source[:offset] + "let current = template" + self.source[offset + len(before):]
                violations = capture_contract_violations(mutated)
                self.assertIn("deferred row actions must not reference the FileTemplate value", violations)
                self.assertIn("each edit action must look up the current template by ID", violations)

    def test_guard_rejects_wrong_confirmation_identity_or_name(self):
        for replacement in (
            "confirmation = .delete(UUID(), name)",
            'confirmation = .delete(id, "Different name")',
        ):
            with self.subTest(replacement=replacement):
                self.assert_rejected_mutation(
                    "confirmation = .delete(id, name)", replacement,
                    "delete must preserve the captured ID and displayed name",
                )

    def test_guard_rejects_whole_template_confirmation_payload(self):
        self.assert_rejected_mutation(
            "case delete(FileTemplate.ID, String)", "case delete(FileTemplate)",
            "delete confirmation must store only ID and name",
        )

    def test_guard_rejects_whole_template_alias_in_row_preamble(self):
        self.assert_rejected_mutation(
            "let isEnabled = template.isEnabled",
            "let isEnabled = template.isEnabled\n        let retainedTemplate = template",
            "row snapshots must contain only ID, name, and Bool",
        )

    def test_guard_rejects_missing_row_instead_of_silently_passing(self):
        self.assertEqual(
            capture_contract_violations(""), ["row boundary changed; review the capture guard"]
        )

    def test_guard_rejects_template_captures_in_copy_drag_and_drop(self):
        for before, after, expected in (
            ('Button("复制") { copyTemplate(withID: id) }',
             'Button("复制") { copyTemplate(withID: template.id) }',
             "copy callback must resolve by captured ID"),
            (".onDrag { beginReorder(withID: id) }", ".onDrag { beginReorder(withID: template.id) }",
             "drag callback must use only captured ID"),
            ("state: $reorderState, targetID: id", "state: $reorderState, targetID: template.id",
             "drop delegate must receive only the target ID"),
        ):
            with self.subTest(before=before):
                self.assert_rejected_mutation(before, after, expected)


if __name__ == "__main__":
    unittest.main()
