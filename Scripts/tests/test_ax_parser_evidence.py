import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Investigations"))
import ax_parser_evidence as E
import test_ax_frozen_nodes as fixtures
from test_ax_frozen_nodes import NODES, Case, totals, tree, trace


class ParserEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary_root = Path(__file__).resolve().parents[2] / ".build/Temporary/parser-evidence-tests"
        cls.temporary_root.mkdir(parents=True, exist_ok=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary_root.rmdir()

    def capture(self, text, nodes=None, target=None, collector=None, index=0, error="Unsupported tree row"):
        collector = collector or E.Collector()
        collector.record("trace" if target else "tree", "baseline", index, "a" * 64,
                         text, None if error is None else ValueError(error), nodes=nodes, target=target)
        E.validate_evidence(collector.value)
        return collector, collector.value["documents"][-1]

    def test_full_c_and_xpc_tree_replay(self):
        c_nodes = {0x1000: 48, 0x2000: 80}
        examples = [(c_nodes, tree(c_nodes, True)), fixtures.ReferenceTests.xpc_tree(False), fixtures.ReferenceTests.xpc_tree(True)]
        for nodes, text in examples:
            with self.subTest(text=text):
                collector, doc = self.capture(text, nodes=nodes)
                replay, anon_nodes, target = E.decode_document(doc)
                original = NODES.parse_tree_graph(text, nodes)
                decoded = NODES.parse_tree_graph(replay, anon_nodes)
                self.assertEqual(len(original["members"]), len(decoded["members"]))
                self.assertEqual(original["roots"][0]["summary"], decoded["roots"][0]["summary"])
                self.assertEqual(len(original["back_edges"]), len(decoded["back_edges"]))
                self.assertIsNone(target)
                self.assertEqual(doc["status"], "complete")

    def test_tree_validation_failures_survive_transcoding(self):
        nodes, valid = fixtures.ReferenceTests.xpc_tree(False)
        for text, expected in (
            (valid.replace("Process 123: 5 leaks", "Process 123: 6 leaks"), "Tree/list totals differ"),
            (valid.replace("3 (432 bytes)", "2 (432 bytes)"), "Incomplete subtree"),
            (valid.replace("0x5000", "0x3000"), "Duplicate or unlisted tree node"),
        ):
            with self.subTest(expected=expected):
                with self.assertRaisesRegex(ValueError, expected):
                    NODES.parse_tree_graph(text, nodes)
                _, doc = self.capture(text, nodes=nodes, error=expected)
                replay, anonymous_nodes, _ = E.decode_document(doc)
                with self.assertRaisesRegex(ValueError, expected):
                    NODES.parse_tree_graph(replay, anonymous_nodes)
                self.assertEqual(doc["error"], E.ERROR_CODES[expected])

    def test_trace_glyphs_and_verified_slot_replay(self):
        text = trace(0x1000, 48, 2).split("    2 <", 1)[0]
        text += ("    2 <private-type 0x1000> [48]\n"
                 "      2 Region Kernel Alloc Once region + 64 0x90000\n"
                 "      + 1 <__NSMallocBlock__ 0x2000> [48] +16: __strong [capture] + 8 0x2010\n"
                 "      + ! 1 Region Stack thread 77 private 0x90010\n"
                 "      + 1 Kernel Pointers Into User Space \n")
        _, doc = self.capture(text, target=(0x1000, 48))
        replay, nodes, target = E.decode_document(doc)
        graph = NODES.parse_trace_graph(replay, *target)
        self.assertEqual((len(graph["members"]), len(graph["edges"]), graph["roots"]), (5, 4, 2))
        self.assertEqual(nodes, {})
        self.assertTrue(any(token[0] == "slot" and token[2] == 16 for line in doc["lines"] for token in line))
        _, bad = self.capture(text.replace("+16:", "+17:"), target=(0x1000, 48))
        replay, _, target = E.decode_document(bad)
        with self.assertRaisesRegex(ValueError, "Unbound reference slot"):
            NODES.parse_trace_graph(replay, *target)

    def test_privacy_unknown_suffix_preamble_and_stable_ids(self):
        nodes = {0xDEADBEEF: 48}
        secret = "SecretPerson123"
        text = tree(nodes).replace("[48]", "[48] " + secret + " /Users/secretperson/Company7788 123456789")
        collector, doc = self.capture(text, nodes=nodes, error="Unsupported object suffix")
        public = E.encode_evidence(collector.value).decode()
        for forbidden in (secret, "secretperson", "Company7788", "123456789", "deadbeef", "Users", "private", "123"):
            self.assertNotIn('"' + forbidden + '"', public)
        self.assertNotIn(secret, public)
        replay, anon_nodes, _ = E.decode_document(doc)
        with self.assertRaisesRegex(ValueError, "Unsupported object suffix"):
            NODES.parse_tree_graph(replay, anon_nodes)
        _, second = self.capture(text, nodes=nodes, collector=collector, index=1)
        self.assertEqual(doc["lines"], second["lines"])
        self.assertEqual(doc["nodes"], second["nodes"])
        preamble = tree(nodes).replace("STACK OF", "privateUnexpectedPreamble99\nSTACK OF", 1)
        _, doc = self.capture(preamble, nodes=nodes)
        replay, anon_nodes, _ = E.decode_document(doc)
        with self.assertRaisesRegex(ValueError, "Unparsed tree prefix"):
            NODES.parse_tree_graph(replay, anon_nodes)

    def test_allowlisted_path_components_cannot_reconstruct_paths(self):
        paths = ("/root/list/offset", r"\root\list\offset", r"C:\root\list\offset", r"\\root\list\offset")
        for path in paths:
            with self.subTest(path=path):
                collector, doc = self.capture(path)
                replay, _, _ = E.decode_document(doc)
                self.assertNotIn(path, replay)
                self.assertNotIn("/", replay)
                self.assertNotIn(chr(92), replay)
                self.assertNotIn(path, E.encode_evidence(collector.value).decode())
                self.assertFalse(any(token[0] == "word" for line in doc["lines"] for token in line))
        for separator in ("/", chr(92)):
            collector, doc = self.capture("placeholder")
            doc["lines"] = [[["punct", separator]]]
            with self.assertRaises(ValueError):
                E.validate_evidence(collector.value)

    def test_addressless_root_replay_preserves_slot_without_inventing_base(self):
        text = trace(0x1000, 48, 1).split("    1 <", 1)[0]
        text += ("    1 <__NSMallocBlock__ 0x1000> [48]\n"
                 "      1 <Swift metadata> +216: __strong 0x70d8\n")
        _, doc = self.capture(text, target=(0x1000, 48), error="Unsupported reverse object")
        replay, _, target = E.decode_document(doc)
        self.assertIn("<Swift metadata> +216: __strong", replay)
        self.assertNotIn("0x70d8", replay)
        graph = NODES.parse_trace_graph(replay, *target)
        slot, = (key for key in graph["members"] if type(key) is tuple)
        self.assertEqual(slot[0], "metadata-slot")
        self.assertEqual(graph["members"][slot]["slot_binding"], ("Swift metadata", 216, target[0]))
        self.assertEqual(set(graph["members"]), {target[0], slot})
        for label in ("PrivateClass PrivateOwner", "/Swift/metadata", "Swift PrivateOwner"):
            _, unknown = self.capture(text.replace("Swift metadata", label), target=(0x1000, 48))
            replay, _, _ = E.decode_document(unknown)
            self.assertNotIn("Private", replay)
            self.assertNotIn("/", replay)
            self.assertEqual(NODES.parse_trace_graph(replay, *target)["roots"], 1)
        _, invalid = self.capture(text.replace("__strong", "privateOwnership"), target=(0x1000, 48))
        replay, _, target = E.decode_document(invalid)
        with self.assertRaisesRegex(ValueError, "Unsupported reverse object"):
            NODES.parse_trace_graph(replay, *target)

    def test_successful_baseline_trace_retains_reviewed_allocation_syntax(self):
        text = trace(0x1000, 48, 1).split("    1 <", 1)[0]
        text += ("    1 <__NSMallocBlock__ 0x1000> [48]\n"
                 "      1 <calloc in _dispatch_continuation_alloc_from_heap 0x2000> [64] +40: 0x2028\n"
                 "        1 <calloc in _dispatch_malloc_continuation_alloc 0x3000> [64] +16: 0x3010\n"
                 "          1 Region Stack thread 77 private 0x90000\n")
        _, doc = self.capture(text, target=(0x1000, 48), error=None)
        replay, _, target = E.decode_document(doc)
        self.assertEqual(doc["error"], "none")
        self.assertIn("calloc in _dispatch_continuation_alloc_from_heap", replay)
        self.assertIn("calloc in _dispatch_malloc_continuation_alloc", replay)
        self.assertEqual(NODES.parse_trace_graph(replay, *target)["roots"], 1)
        self.assertEqual([token[2] for line in doc["lines"] for token in line if token[0] == "slot"], [40, 16])
        for key, value in (("tool", "tree"), ("label", "added-10")):
            changed = copy.deepcopy(doc)
            changed[key] = value
            with self.assertRaises(ValueError):
                E.validate_evidence({"schema": 1, "status": "complete", "documents": [changed], "omitted_documents": 0})

    def test_bounded_lines_tokens_documents_and_bytes(self):
        for text in ("X" * (E.LINE_LENGTH_LIMIT + 1), "x\n" * (E.LINE_LIMIT + 1),
                     ("x " * 4096 + "\n") * 10):
            collector, doc = self.capture(text)
            self.assertEqual(doc["status"], "truncated")
            self.assertEqual(collector.value["status"], "truncated")
        collector = E.Collector()
        for index in range(E.DOCUMENT_LIMIT + 1):
            self.capture("x", collector=collector, index=index)
        self.assertEqual(collector.value["omitted_documents"], 1)
        collector = E.Collector()
        for index in range(10):
            self.capture(("x " * 100 + "\n") * 250, collector=collector, index=index)
        self.assertLessEqual(len(E.encode_evidence(collector.value)), E.EVIDENCE_LIMIT)
        self.assertEqual(collector.value["status"], "truncated")

    def test_fixed_schema_rejects_raw_text_and_unbounded_values(self):
        collector, _ = self.capture("\t├─→ secret")
        original = collector.value
        for mutate in (
            lambda v: v.update(raw="private"),
            lambda v: v["documents"][0].update(error="private error"),
            lambda v: v["documents"][0]["lines"].append([["word", "private"]]),
            lambda v: v["documents"][0]["lines"].append([["raw", "private"]]),
            lambda v: v["documents"][0]["lines"].append([["number", 1 << 62]]),
            lambda v: v["documents"][0]["lines"].append([["space", E.LINE_LENGTH_LIMIT + 1]]),
            lambda v: v["documents"][0]["lines"].append([["opaque", True]]),
        ):
            value = copy.deepcopy(original)
            mutate(value)
            with self.assertRaises(ValueError):
                E.validate_evidence(value)

    def test_main_writes_summary_before_independent_evidence(self):
        with tempfile.TemporaryDirectory(dir=self.temporary_root) as directory:
            case = Case(Path(directory), before={0x1000: 48}, after={0x1000: 48, 0x2000: 80})
            case.failures[("tree", "added-10")] = "private malformed report"
            argv = ["--graph-directory", str(case.graphs), "--records-directory", str(case.records), "--first-strict-growth"]
            with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(NODES.main(argv), 1)
            summary = json.loads((case.records / "frozen-nodes.json").read_bytes())
            NODES.validate_summary(summary)
            self.assertEqual(summary["schema"], 2)
            evidence = json.loads((case.records / "parser-evidence.json").read_bytes())
            E.validate_evidence(evidence)
            self.assertEqual(len(evidence["documents"]), 2)
            self.assertEqual([doc["error"] for doc in evidence["documents"]], ["missing_unique_leak_totals", "none"])
            self.assertNotIn("parser_evidence", summary)
            (case.records / "frozen-nodes-private").rmdir()
            with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run), mock.patch.object(NODES, "validate_evidence", side_effect=ValueError), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(NODES.main(argv), 1)
            self.assertEqual(json.loads((case.records / "frozen-nodes.json").read_bytes()), summary)

    def test_compare_preserves_failures_and_receipt_binding(self):
        with tempfile.TemporaryDirectory(dir=self.temporary_root) as directory:
            case = Case(Path(directory), before={0x1000: 48}, after={0x1000: 48, 0x2000: 80})
            case.failures[("tree", "baseline")] = tree(case.points["baseline"]) + ""
            case.failures[("tree", "added-10")] = "private malformed report"
            case.failures[("trace", "added-10")] = "private malformed report"
            collector = E.Collector()
            with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run):
                plain = NODES.compare(case.graphs, case.records, first_strict_growth=True)
            # The fake runner does not write private reports; Tools still owns its directory.
            (case.records / "frozen-nodes-private").rmdir()
            with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run):
                captured = NODES.compare(case.graphs, case.records, first_strict_growth=True, collector=collector)
            self.assertEqual(plain, captured)
            self.assertIn("tree_invalid", captured["reasons"])
            self.assertIn("references_invalid", captured["reasons"])
            E.validate_evidence(collector.value)
            self.assertEqual(len(collector.value["documents"]), 3)
            for doc in collector.value["documents"]:
                receipt = captured["tools"][doc["tool_index"]]
                self.assertEqual((receipt["tool"], receipt["label"], receipt["status"]), (doc["tool"], doc["label"], "complete"))
                point = captured["baseline"] if doc["label"] == "baseline" else captured["selected"]
                self.assertEqual(doc["graph_sha256"], point["graph_sha256"])

    def test_reference_budgets_keep_failure_docs_without_unbound_success(self):
        for budget in ("references", "summary"):
            with self.subTest(budget=budget), tempfile.TemporaryDirectory(dir=self.temporary_root) as directory:
                case = Case(Path(directory), before={0x1000: 48}, after={0x1000: 48, 0x2000: 80})
                case.failures[("tree", "baseline")] = "private malformed report"
                case.failures[("trace", "baseline")] = trace(0x2000, 80, 512 if budget == "references" else 50)
                collector = E.Collector()
                with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=case.run), \
                        mock.patch.object(NODES, "PUBLIC_LIMIT", NODES.PUBLIC_LIMIT if budget == "references" else 10000):
                    result = NODES.compare(case.graphs, case.records, first_strict_growth=True, collector=collector)
                NODES.validate_summary(result)
                E.validate_evidence(collector.value)
                self.assertIn("references_budget" if budget == "references" else "summary_budget", result["reasons"])
                self.assertEqual([doc["error"] for doc in collector.value["documents"]], ["missing_unique_leak_totals"])
                self.assertEqual(collector.value["omitted_documents"], 1)
                self.assertEqual(collector.value["status"], "truncated")


if __name__ == "__main__":
    unittest.main()
