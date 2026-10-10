"""Checks collection and classification together without operating Finder."""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "finder_menu_state", ROOT / "Scripts/Investigations/finder-menu-state.py"
)
STATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATE)


def observed_menu_titles(source):
    match = re.search(r'\[([^\[\]]*)\]\.contains\(elementTitle\)', source)
    if match is None:
        raise AssertionError("Geometry title filter changed; review this contract")
    return set(re.findall(r'"([^"\\]*)"', match[1]))


class FinderMenuObservationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.presentation = (ROOT / "FinderExtension/FinderMenuPresentation.swift").read_text()
        cls.geometry = (ROOT / "Scripts/Investigations/NativeMenuGeometry.swift").read_text()

    def row(self, title, width=120, height=22):
        return {"title": title, "width": width, "height": height}

    def loading_titles(self):
        titles = []
        for state in ("destinationLoading", "templatesLoading"):
            match = re.search(r'case \.' + state + r':\s*return "([^"\\]*)"', self.presentation)
            self.assertIsNotNone(match, "Product loading state changed; review the observation contract")
            titles.append(match[1])
        return titles

    def test_both_current_product_loading_states_survive_geometry_and_require_reopen(self):
        titles = observed_menu_titles(self.geometry)
        for title in self.loading_titles():
            with self.subTest(title=title):
                self.assertIn(title, titles)
                rows = [self.row(title)] if title in titles else []
                self.assertIs(STATE.submenu_requires_reopen(rows, "Owned 000 (.txt)"), True)
        self.assertEqual(STATE.LOADING_TITLES, set(self.loading_titles()))

    def test_visible_creation_row_is_ready(self):
        title = "Owned 000 (.txt)"
        self.assertIn(title, observed_menu_titles(self.geometry))
        self.assertIs(STATE.submenu_requires_reopen([self.row(title)], title), False)

    def test_hidden_loading_rows_do_not_claim_reopen(self):
        for title in self.loading_titles():
            for width, height in ((0, 22), (120, 0), (-1, 22)):
                with self.subTest(title=title, width=width, height=height):
                    self.assertIsNone(STATE.submenu_requires_reopen([self.row(title, width, height)], "Owned 000 (.txt)"))

    def test_hidden_creation_row_does_not_claim_ready(self):
        title = "Owned 000 (.txt)"
        self.assertIsNone(STATE.submenu_requires_reopen([self.row(title, height=0)], title))

    def test_root_navigation_and_unknown_rows_do_not_claim_ready(self):
        for rows in ([], [self.row("新建文件")], [self.row("在 QuickFile 中创建…")], [self.row("未知状态")]):
            with self.subTest(rows=rows):
                self.assertIsNone(STATE.submenu_requires_reopen(rows, "Owned 000 (.txt)"))

    def test_visible_creation_wins_over_loading_from_other_menu_branch(self):
        rows = [self.row(self.loading_titles()[0]), self.row("Owned 000 (.txt)")]
        self.assertIs(STATE.submenu_requires_reopen(rows, "Owned 000 (.txt)"), False)


if __name__ == "__main__":
    unittest.main()
