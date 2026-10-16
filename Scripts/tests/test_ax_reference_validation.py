"""Self-authored frozen fixtures: no captured process identities or output."""
import contextlib
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Investigations"))
sys.path.insert(0, str(HERE))
import ax_reference_validation as ref
from test_ax_frozen_nodes import Case, NODES, heap, history, listing, trace, tree

TEMP = HERE.parents[1] / ".build/Temporary/ax-reference-verification-20261012"
P, M, R, U = 0x1000, 0x2000, 0x3000, 0x4000


class Fixture(Case):
    def __init__(self, root, growth=False, roots=2, candidate_size=48, extra_candidates=0):
        before = {R + n * 0x1000: 384 for n in range(roots)}
        candidates = {M: candidate_size, **{0x10000 + n * 0x1000: 64 for n in range(extra_candidates)}} if growth else {}
        after = {**before, **candidates}
        super().__init__(root, before=before, after=after)
        self.growth = growth
        self.baseline_heap = {**before, **({P: 64, **candidates} if growth else {})}
        self.inventories = {label: {key: size for key, size in self.baseline_heap.items()
                                   if not (growth and label != "baseline" and key == P)} for label in NODES.HEAP_LABELS}
        self.events = {label: [("ALLOC", key, size) for key, size in self.baseline_heap.items()] +
                      ([("FREE", P, 64)] if growth and label != "baseline" else []) for label in NODES.HEAP_LABELS}
        self.overrides, self.trace_overrides = {}, {}
        (self.records / "process-cleanup.json").write_bytes(ref.encode({"processes_exited": True, "errors": [],
            "host": {"exited": True, "errors": []}, "reader": {"exited": True, "errors": []}}))
        (self.records / "reference-validation-input.json").write_bytes(ref.encode({**ref.PROTOCOL,
            "checkpoint_windows": [{"label": label, "phase": label, "start_monotonic": index * 2,
                                    "end_monotonic": index * 2 + 1} for index, label in enumerate(NODES.HEAP_LABELS)]}))
        self.context = {}
        with mock.patch.object(NODES.Tools, "run", autospec=True, side_effect=self.run):
            self.frozen = NODES.compare(self.graphs, self.records, first_strict_growth=True, bridge_context=self.context)
        NODES.validate_summary(self.frozen)
        assert self.frozen["status"] == "complete", self.frozen["reasons"]
        self.bridge = ref.bridge_module.collect(frozen=self.frozen, traces=self.context["traces"],
            baseline_heap=self.context["baseline_heap"], before_graph=self.context.get("before_graph"),
            after_graph=self.context.get("after_graph"), tools=FakeTools(self), reference_ids=self.context["reference_ids"])
        ref.bridge_module.validate_summary(self.bridge, self.frozen)
        assert self.bridge["status"] in ("complete", "not_needed"), self.bridge["reasons"]
        mapping = self.context["reference_ids"]
        self.private_context = {"frozen_sha256": ref.digest(self.frozen),
            "addresses": [[number, key] for key, number in mapping.items() if type(key) is int],
            "next_id": max(mapping.values(), default=-1) + 1}
        (self.records / "frozen-nodes.json").write_bytes(NODES.encode_summary(self.frozen))
        (self.records / "bridge-evidence.json").write_bytes(ref.bridge_module.encode_summary(self.bridge, self.frozen))
        self.calls.clear()

    def run(self, owner, kind, label, command, allowed=(0,)):
        self.calls.append((kind, label, command))
        owner.summary["tools"].append({"tool": kind, "label": label, "status": "complete", "return_code": 0, "cleanup_confirmed": True})
        label = self.frozen["selected_label"] if label == "selected" else label
        failure = self.failures.get((kind, label))
        if failure:
            if isinstance(failure, NODES.ExitUnconfirmed):
                owner.summary["tools"][-1].update(status="timeout", return_code=None, cleanup_confirmed=False)
                owner.summary["process_cleanup_confirmed"] = False
            raise failure
        if (kind, label) in self.overrides:
            return self.overrides[(kind, label)]
        if kind == "list": return listing(self.points[label])
        if kind == "tree": return tree(self.points[label]).replace("NSString", "NSXPCConnection")
        if kind == "heap": return heap(self.inventories[label])
        if kind == "heap_diff": return heap({})
        if kind == "history": return history(self.events[label])
        if kind == "trace":
            address = int(command[-2].split("=")[1], 16)
            size = self.inventories[label][address]
            if (label, address) in self.trace_overrides: return self.trace_overrides[(label, address)]
            if self.growth and label == "baseline" and address == M:
                return trace(M, size, 1).split("    1 <", 1)[0] + (
                    f"    1 <private-type {M:#x}> [{size}]\n"
                    f"      1 <private allocator {P:#x}> [64] +40: {P + 40:#x}\n"
                    "        1 Region Stack private 0x90000\n")
            return trace(address, size, 0)
        if kind == "layout":
            return (f"SCANNING <private allocator {P:#x}> [64]\nREFERENCES TO THIS: 0\n"
                    f"CONTENTS:\n   +40: {P + 40:#x} --> <private-type {M:#x}> [48]\n")
        raise AssertionError("Unexpected tool")

    def collect(self):
        tools = FakeTools(self)
        value = ref.collect(frozen=self.frozen, bridge=self.bridge, context=self.private_context,
                            graphs=self.graphs, records=self.records, tools=tools)
        ref.validate_summary(value, self.frozen, self.bridge,
            {label: NODES.graph_hash(self.graphs / (label + ".memgraph")) for label in NODES.HEAP_LABELS})
        return value


class FakeTools:
    def __init__(self, fixture):
        self.fixture = fixture
        self.summary = {"tools": [], "process_cleanup_confirmed": True}

    def run(self, kind, label, command, allowed=(0,)):
        return self.fixture.run(self, kind, label, command, allowed)


class ReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TEMP.mkdir(parents=True, exist_ok=True)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=TEMP, prefix="sidecar-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_no_growth_uses_last_checkpoint_and_retains_same_generation_roots(self):
        fixture = Fixture(self.root)
        value = fixture.collect()
        self.assertEqual((value["status"], value["selection"], value["selected_label"]),
                         ("complete", "last-checkpoint", "observer-exited"))
        self.assertEqual(len(value["selected_roots"]), 2)
        self.assertTrue(all(obj["baseline_to_selected"] == "same_generation" for obj in value["objects"]))
        self.assertTrue(all(obj["first_visible"]["heap"]["state"] == "at_baseline" for obj in value["objects"]))
        self.assertEqual(value["clock_availability"], "checkpoint_windows")
        self.assertEqual(len(value["tools"]), 32)
        payload = ref.encode_summary(value, fixture.frozen, fixture.bridge)
        self.assertLessEqual(len(payload), 128 * 1024)
        for secret in (b"0x", b"private allocator", str(self.root).encode(), b"malloc_history", b"memgraph"):
            self.assertNotIn(secret, payload)

    def test_freed_source_skips_layout_and_third_root_is_preexisting_heap(self):
        fixture = Fixture(self.root, growth=True)
        value = fixture.collect()
        pair = value["bridges"][0]
        objects = {obj["id"]: obj for obj in value["objects"]}
        self.assertEqual(objects[pair["source"]]["baseline_to_selected"], "freed")
        self.assertEqual(objects[pair["target"]]["baseline_to_selected"], "same_generation")
        self.assertEqual(pair["layouts"][0]["state"], "original_target_address")
        self.assertEqual(pair["layouts"][1]["state"], "source_absent")
        self.assertEqual([(kind, label) for kind, label, _ in fixture.calls if kind == "layout"], [("layout", "baseline")])
        self.assertEqual(len(value["selected_roots"]), 3)
        target = objects[pair["target"]]
        self.assertEqual(target["first_visible"]["heap"]["state"], "at_baseline")
        self.assertEqual(target["first_visible"]["root_kind"], {"state": "between_checkpoints", "after": "baseline", "through": "added-10"})
        self.assertEqual(target["timeline"][0]["root_kind"], "none")
        incoming = next(row for row in value["references"]["differences"] if row["object_id"] == pair["target"] and row["kind"] == "incoming")
        self.assertIn([pair["source"], pair["target"], "unlabeled", "reverse_reference"], incoming["removed"])
        self.assertEqual(value["ownership"], "not-established")
        self.assertEqual(value["identity"], "same-run-address")
        self.assertEqual(value["status"], "partial")  # Allocated non-leaked objects have no reported outgoing tree.
        self.assertEqual(value["allocation_stack"], "unavailable")
        self.assertEqual(value["allocation_clock"], "unavailable")
        membership = next(row for row in value["root_memberships"] if row["root_id"] == pair["target"])
        self.assertEqual(membership["baseline_heap"], {"present": 1, "absent": 0, "unknown": 0})
        self.assertEqual(membership["baseline_leaked_members"], 0)

    def test_non_bridge_64_byte_candidate_is_included_and_overflow_is_explicit(self):
        fixture = Fixture(self.root, growth=True, candidate_size=64, extra_candidates=10)
        value = fixture.collect()
        self.assertEqual(value["bridges"], [])
        candidates = [obj for obj in value["objects"] if "growth_candidate" in obj["roles"]]
        self.assertTrue(candidates)
        self.assertEqual(len(candidates) + value["omitted_candidates"], 11)
        self.assertGreater(value["omitted_candidates"], 0)
        self.assertIn("candidate_limit", value["reasons"])
        self.assertLessEqual(len(value["objects"]), ref.OBJECT_LIMIT)
        self.assertLessEqual(len(value["tools"]), ref.TOOL_LIMIT)

    def test_cycle_overlap_counts_all_members_without_claiming_closed_cycle(self):
        selected = NODES.parse_tree_graph(tree({R: 384, M: 64}, True).replace("NSString", "NSXPCConnection"), {R: 384, M: 64})
        baseline = NODES.parse_tree_graph(tree({R: 384, U: 64}, True), {R: 384, U: 64})
        row = ref.root_membership(selected["roots"][0], selected, baseline, {R: 384, U: 64}, {R: 384, U: 64}, lambda _: 0)
        self.assertEqual(row["selected_members"], 2)
        self.assertEqual(row["baseline_heap"], {"present": 1, "absent": 1, "unknown": 0})
        self.assertEqual((row["baseline_cycle_members"], row["baseline_cycle_roots"]), (1, 1))
        unknown = ref.root_membership(selected["roots"][0], selected, None, None, None, lambda _: 0)
        self.assertEqual(unknown["baseline_heap"]["unknown"], 2)
        self.assertIsNone(unknown["baseline_cycle_members"])

    def test_data_block_path_selects_only_verified_heap_member(self):
        fixture = Fixture(self.root)
        block = 0x9000
        for label in NODES.HEAP_LABELS:
            fixture.inventories[label][block] = 32
            fixture.events[label].append(("ALLOC", block, 32))
        report = trace(R, 384, 1).split("    1 <", 1)[0] + (
            f"    1 <private-type {R:#x}> [384]\n"
            f"      1 <__NSMallocBlock__ {block:#x}> [32] +16: __strong [capture] {block + 16:#x}\n"
            "        1 Region __DATA private-image 0x99900\n")
        for label in ("baseline", "observer-exited"): fixture.trace_overrides[(label, R)] = report
        value = fixture.collect()
        upstream = [obj for obj in value["objects"] if "upstream_heap" in obj["roles"]]
        self.assertEqual(len(upstream), 1)
        self.assertEqual(upstream[0]["baseline_to_selected"], "same_generation")
        diff = next(row for row in value["references"]["differences"] if row["object_id"] == value["selected_roots"][0] and row["kind"] == "incoming")
        self.assertEqual((diff["added"], diff["removed"], diff["retained"]), ([], [], 2))
        self.assertNotIn("private-image", ref.encode_summary(value, fixture.frozen, fixture.bridge).decode())

    def test_missing_history_does_not_certify_address_generation(self):
        fixture = Fixture(self.root)
        fixture.overrides[("history", "registered-10")] = "unsupported private history\n"
        value = fixture.collect()
        self.assertEqual(value["status"], "partial")
        self.assertIn("history_unavailable", value["reasons"])
        self.assertIn("allocation_unknown", value["reasons"])
        self.assertTrue(all(obj["generations"][1]["generation"] == "unknown" for obj in value["objects"]))

    def test_cross_view_private_slot_conflicts_are_partial_without_publishing_binding(self):
        fixture = Fixture(self.root)
        for slot in ("<private metadata> +8: __strong 0x99908", "Thread 7 private thread $x25"):
            with self.subTest(slot=slot):
                fixture.trace_overrides.clear()
                for address in (R, U):
                    fixture.trace_overrides[("baseline", address)] = trace(address, 384, 1).split("    1 <", 1)[0] + (
                        f"    1 <private-type {address:#x}> [384]\n      1 {slot}\n")
                value = fixture.collect()
                self.assertEqual(value["status"], "partial")
                self.assertIn("reference_conflict", value["reasons"])
                incoming = [view for view in value["references"]["views"]
                            if view["checkpoint"] == "baseline" and view["kind"] == "incoming"]
                self.assertEqual([view["state"] for view in incoming], ["complete", "unknown"])
                self.assertEqual((incoming[1]["nodes"], incoming[1]["edges"], incoming[1]["root_count"]), ([], [], None))
                self.assertEqual(len(value["references"]["edges"]), 1)
                encoded = ref.encode_summary(value, fixture.frozen, fixture.bridge).decode()
                for private in ("slot_binding", "private metadata", "private thread", "0x99908", "$x25"):
                    self.assertNotIn(private, encoded)
                # A changed slot value in a different checkpoint is not a
                # same-snapshot conflict; it remains an address relation only.
                fixture.trace_overrides[("observer-exited", U)] = fixture.trace_overrides.pop(("baseline", U))
                independent = fixture.collect()
                self.assertEqual(independent["status"], "complete")
                self.assertNotIn("reference_conflict", independent["reasons"])

    def test_reused_address_with_equal_size_is_not_same_generation(self):
        fixture = Fixture(self.root)
        for label in NODES.HEAP_LABELS[1:]:
            fixture.events[label] += [("FREE", R, 384), ("ALLOC", R, 384)]
        value = fixture.collect()
        self.assertEqual(value["objects"][0]["baseline_to_selected"], "reused")
        self.assertEqual(value["objects"][0]["generations"][0]["events"], {"allocs": 1, "frees": 1})

    def test_unconfirmed_tool_exit_aborts_and_keeps_bound_partial_checkpoint(self):
        fixture = Fixture(self.root)
        fixture.failures[("tree", "baseline")] = NODES.ExitUnconfirmed()
        value = fixture.collect()
        self.assertFalse(value["process_cleanup_confirmed"])
        self.assertEqual([(kind, label) for kind, label, _ in fixture.calls], [("list", "baseline"), ("tree", "baseline")])
        self.assertEqual(value["checkpoints"][0]["tools"]["list"], 0)
        self.assertEqual(value["objects"], [])

    def test_no_clock_does_not_invent_allocation_time(self):
        fixture = Fixture(self.root)
        (fixture.records / "reference-validation-input.json").write_bytes(ref.encode(ref.PROTOCOL))
        value = fixture.collect()
        self.assertEqual((value["clock_availability"], value["checkpoint_windows"]), ("unavailable", []))
        self.assertEqual(value["status"], "complete")

    def test_root_budget_is_explicit(self):
        fixture = Fixture(self.root, roots=6)
        value = fixture.collect()
        self.assertEqual((value["status"], value["omitted_roots"], len(value["selected_roots"])), ("partial", 2, 4))
        self.assertIn("root_limit", value["reasons"])

    def test_independent_gate_rejects_private_fields_wrong_bindings_and_fabricated_generation(self):
        fixture = Fixture(self.root)
        value = fixture.collect()
        for mutation in (
            lambda v: v.update(raw="private"), lambda v: v.update(frozen_sha256="f" * 64),
            lambda v: v["checkpoints"][0].update(graph_sha256="f" * 64),
            lambda v: v["objects"][0].update(baseline_to_selected="reused"),
            lambda v: v["objects"][0]["timeline"][0].update(type="private-type"),
            lambda v: v["references"]["views"][0].update(tool_index=0),
            lambda v: v["references"]["differences"][0].update(retained=999),
            lambda v: v["checkpoint_windows"][0].update(start_monotonic=float("nan")),
            lambda v: v.update(checkpoint_windows={}),
            lambda v: v["root_memberships"][0]["baseline_heap"].update(unknown=1, present=0),
            lambda v: v["tools"][0].update(cleanup_confirmed=False),
        ):
            changed = copy.deepcopy(value)
            mutation(changed)
            with self.subTest(changed=changed), self.assertRaises((ValueError, TypeError)):
                ref.validate_summary(changed, fixture.frozen, fixture.bridge)
        hashes = {row["label"]: row["graph_sha256"] for row in value["checkpoints"]}
        hashes["removed-20"] = "a" * 64
        with self.assertRaises(ValueError): ref.validate_summary(value, fixture.frozen, fixture.bridge, hashes)

    def test_input_protocol_and_cleanup_refuse_worker_launch(self):
        fixture = Fixture(self.root)
        names = ("process-cleanup.json", "reference-validation-input.json", "result.json")
        originals = {name: (fixture.records / name).read_bytes() for name in names}
        changes = (("process-cleanup.json", {"processes_exited": False}),
                   ("process-cleanup.json", {"processes_exited": True, "errors": []}),
                   ("reference-validation-input.json", {**ref.PROTOCOL, "malloc_stack_logging": "1"}),
                   ("result.json", {"scan_mode": "diagnostic", "live_attribution": True}))
        for name, changed in changes:
            (fixture.records / name).write_bytes(ref.encode(changed))
            with self.subTest(name=name, changed=changed), mock.patch.object(ref, "run_owned") as run:
                self.assertFalse(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
                run.assert_not_called()
                value = json.loads((fixture.records / "reference-validation.json").read_bytes())
                ref.validate_summary(value, fixture.frozen, fixture.bridge)
                self.assertEqual(value["status"], "partial")
            (fixture.records / name).write_bytes(originals[name])

    def test_worker_group_result_is_gated_and_private_output_cleaned(self):
        fixture = Fixture(self.root)
        value = fixture.collect()
        originals = {name: (fixture.records / name).read_bytes() for name in ("frozen-nodes.json", "bridge-evidence.json", "scans.json")}
        def owned(command, logfile, environment, timeout):
            self.assertEqual(timeout, ref.SECONDS + 5)
            self.assertIn("--worker", command)
            private = fixture.records / "reference-validation-private"
            ref.validate_context(json.loads((private / "context.json").read_bytes()), fixture.frozen)
            (private / "result.json").write_bytes(ref.encode_summary(value, fixture.frozen, fixture.bridge))
            logfile.write_text("private raw output")
            return {"status": "completed", "command_return_code": 0, "cleanup": {"complete": True}}
        with mock.patch.object(ref, "run_owned", side_effect=owned):
            self.assertTrue(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
        self.assertFalse((fixture.records / "reference-validation-private").exists())
        self.assertEqual(originals, {name: (fixture.records / name).read_bytes() for name in originals})
        with mock.patch.object(ref, "run_owned", return_value={"status": "timeout", "command_return_code": None, "cleanup": {"complete": False}}):
            self.assertFalse(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
        bad = json.loads((fixture.records / "reference-validation.json").read_bytes())
        ref.validate_summary(bad, fixture.frozen, fixture.bridge)
        self.assertFalse(bad["process_cleanup_confirmed"])
        self.assertTrue((fixture.records / "reference-validation-private").exists())

    def test_cleanup_failure_is_fixed_partial_not_raw_exception(self):
        fixture = Fixture(self.root)
        with mock.patch.object(ref, "run_owned", return_value={"status": "completed", "command_return_code": 1, "cleanup": {"complete": True}}), \
                mock.patch.object(ref.shutil, "rmtree", side_effect=OSError("private path")):
            self.assertFalse(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
        value = json.loads((fixture.records / "reference-validation.json").read_bytes())
        self.assertIn("private_cleanup_failed", value["reasons"])
        self.assertNotIn("private path", json.dumps(value))

    def worker_result(self, fixture, value, *, confirmed=True):
        def owned(command, logfile, environment, timeout):
            (logfile.parent / "result.json").write_bytes(ref.encode_summary(value, fixture.frozen, fixture.bridge))
            logfile.write_text("private worker output")
            return {"status": "completed", "command_return_code": 0, "cleanup": {"complete": confirmed}}
        return owned

    def test_first_publication_failure_preserves_old_summary_and_private_evidence(self):
        for failure in ("encode", "write", "rename"):
            for previous in (False, True):
                with self.subTest(failure=failure, previous=previous):
                    root = self.root / (failure + str(previous)); root.mkdir()
                    fixture = Fixture(root)
                    value = fixture.collect()
                    target = fixture.records / "reference-validation.json"
                    temporary = target.with_suffix(".tmp")
                    old = copy.deepcopy(value)
                    ref.reason(old, "original_partial")
                    old_payload = ref.encode_summary(old, fixture.frozen, fixture.bridge)
                    if previous: target.write_bytes(old_payload)
                    real_write, real_replace, real_encode = Path.write_bytes, Path.replace, ref.encode_summary
                    def write(path, payload):
                        if path == temporary and failure == "write":
                            real_write(path, payload[:20])
                            raise OSError("private write error")
                        return real_write(path, payload)
                    def replace(path, destination):
                        if path == temporary and failure == "rename":
                            raise OSError("private rename error")
                        return real_replace(path, destination)
                    def encode(summary, frozen, bridge):
                        if "private_cleanup_pending" in summary["reasons"] and failure == "encode":
                            raise ValueError("private encoding error")
                        return real_encode(summary, frozen, bridge)
                    with mock.patch.object(ref, "run_owned", side_effect=self.worker_result(fixture, value)), \
                            mock.patch.object(Path, "write_bytes", write), mock.patch.object(Path, "replace", replace), \
                            mock.patch.object(ref, "encode_summary", side_effect=encode), \
                            mock.patch.object(ref.shutil, "rmtree") as cleanup:
                        self.assertFalse(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
                        cleanup.assert_not_called()
                    if previous:
                        self.assertEqual(target.read_bytes(), old_payload)
                    else:
                        self.assertFalse(target.exists())
                    self.assertFalse(temporary.exists())
                    private = fixture.records / "reference-validation-private"
                    self.assertEqual(json.loads((private / "result.json").read_bytes()), value)
                    self.assertEqual((private / "worker.log").read_text(), "private worker output")

    def test_cleanup_requires_published_pending_checkpoint_and_failure_is_recorded(self):
        fixture = Fixture(self.root)
        value = fixture.collect()
        def cleanup(private):
            checkpoint = json.loads((fixture.records / "reference-validation.json").read_bytes())
            ref.validate_summary(checkpoint, fixture.frozen, fixture.bridge)
            self.assertEqual(checkpoint["status"], "partial")
            self.assertEqual(checkpoint["reasons"], ["private_cleanup_pending"])
            self.assertEqual(checkpoint["objects"], value["objects"])
            self.assertTrue((private / "worker.log").is_file())
            raise OSError("private cleanup error")
        with mock.patch.object(ref, "run_owned", side_effect=self.worker_result(fixture, value)), \
                mock.patch.object(ref.shutil, "rmtree", side_effect=cleanup):
            self.assertFalse(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
        final = json.loads((fixture.records / "reference-validation.json").read_bytes())
        ref.validate_summary(final, fixture.frozen, fixture.bridge)
        self.assertEqual(final["status"], "partial")
        self.assertEqual(final["reasons"], ["private_cleanup_failed"])
        self.assertTrue((fixture.records / "reference-validation-private/worker.log").is_file())
        self.assertNotIn("private cleanup error", json.dumps(final))

    def test_final_publication_failure_keeps_measured_pending_checkpoint(self):
        for cleanup_failed in (False, True):
            for failure in ("encode", "write", "rename"):
                with self.subTest(cleanup_failed=cleanup_failed, failure=failure):
                    root = self.root / (str(cleanup_failed) + failure); root.mkdir()
                    fixture = Fixture(root)
                    value = fixture.collect()
                    target = fixture.records / "reference-validation.json"
                    temporary = target.with_suffix(".tmp")
                    real_write, real_replace, real_cleanup, real_encode = Path.write_bytes, Path.replace, ref.shutil.rmtree, ref.encode_summary
                    def write(path, payload):
                        if path == temporary and target.exists() and failure == "write":
                            real_write(path, payload[:20])
                            raise OSError("private final write error")
                        return real_write(path, payload)
                    def replace(path, destination):
                        if path == temporary and target.exists() and failure == "rename":
                            raise OSError("private final rename error")
                        return real_replace(path, destination)
                    def cleanup(private):
                        if cleanup_failed: raise OSError("private cleanup error")
                        return real_cleanup(private)
                    def encode(summary, frozen, bridge):
                        if target.exists() and "private_cleanup_pending" not in summary["reasons"] and failure == "encode":
                            raise ValueError("private final encoding error")
                        return real_encode(summary, frozen, bridge)
                    with mock.patch.object(ref, "run_owned", side_effect=self.worker_result(fixture, value)), \
                            mock.patch.object(Path, "write_bytes", write), mock.patch.object(Path, "replace", replace), \
                            mock.patch.object(ref, "encode_summary", side_effect=encode), \
                            mock.patch.object(ref.shutil, "rmtree", side_effect=cleanup):
                        self.assertFalse(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
                    final = json.loads(target.read_bytes())
                    ref.validate_summary(final, fixture.frozen, fixture.bridge)
                    self.assertEqual(final["status"], "partial")
                    self.assertEqual(final["reasons"], ["private_cleanup_pending"])
                    self.assertEqual(final["objects"], value["objects"])
                    self.assertEqual((fixture.records / "reference-validation-private").exists(), cleanup_failed)
                    self.assertFalse(temporary.exists())

    def test_public_summary_and_staging_symlinks_preserve_destination_and_private_evidence(self):
        for linked in ("reference-validation.json", "reference-validation.tmp"):
            with self.subTest(linked=linked):
                root = self.root / linked; root.mkdir()
                fixture = Fixture(root)
                value = fixture.collect()
                destination = root / "unrelated"
                destination.write_text("untouched")
                (fixture.records / linked).symlink_to(destination)
                with mock.patch.object(ref, "run_owned", side_effect=self.worker_result(fixture, value)), \
                        mock.patch.object(ref.shutil, "rmtree") as cleanup:
                    self.assertFalse(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
                    cleanup.assert_not_called()
                self.assertEqual(destination.read_text(), "untouched")
                self.assertTrue((fixture.records / linked).is_symlink())
                self.assertTrue((fixture.records / "reference-validation-private/worker.log").is_file())

    def test_unconfirmed_worker_exit_retains_private_result_and_log(self):
        fixture = Fixture(self.root)
        value = fixture.collect()
        with mock.patch.object(ref, "run_owned", side_effect=self.worker_result(fixture, value, confirmed=False)), \
                mock.patch.object(ref.shutil, "rmtree") as cleanup:
            self.assertFalse(ref.write_sidecar(fixture.frozen, fixture.context, fixture.graphs, fixture.records))
            cleanup.assert_not_called()
        final = json.loads((fixture.records / "reference-validation.json").read_bytes())
        ref.validate_summary(final, fixture.frozen, fixture.bridge)
        self.assertFalse(final["process_cleanup_confirmed"])
        self.assertIn("process_exit_unconfirmed", final["reasons"])
        self.assertTrue((fixture.records / "reference-validation-private/worker.log").is_file())

    def test_tool_budget_and_deadline_refuse_new_child(self):
        summary = {"tools": [{}] * ref.TOOL_LIMIT, "process_cleanup_confirmed": True}
        tools = ref.Tools(self.root / "tools", summary, time.monotonic() + ref.SECONDS)
        with mock.patch.object(ref.frozen_module.subprocess, "Popen") as popen:
            with self.assertRaises(NODES.EvidenceError): tools.run("list", "baseline", ["unused"])
            summary["tools"].clear()
            tools.deadline = time.monotonic() - 1
            with self.assertRaises(NODES.EvidenceError): tools.run("list", "baseline", ["unused"])
            popen.assert_not_called()

    def test_cli_opt_in_rejects_live_or_missing_prerequisites_before_compare(self):
        base = ["--graph-directory", str(self.root), "--records-directory", str(self.root), "--reference-validation"]
        for flags in ([], ["--first-strict-growth"], ["--bridge-evidence"], ["--live-pair", "--bridge-evidence"]):
            with mock.patch.object(NODES, "compare") as compare, contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit): NODES.main(base + flags)
                compare.assert_not_called()

    def test_cli_saves_originals_before_sidecar_and_keeps_sidecar_failure(self):
        fixture = Fixture(self.root)
        def sidecar(frozen, context, graphs, records):
            self.assertEqual(json.loads((records / "frozen-nodes.json").read_bytes()), frozen)
            self.assertTrue((records / "parser-evidence.json").is_file())
            bridge = json.loads((records / "bridge-evidence.json").read_bytes())
            ref.bridge_module.validate_summary(bridge, frozen)
            return False
        with mock.patch.object(NODES, "compare", return_value=fixture.frozen), \
                mock.patch.object(NODES, "write_bridge_evidence", return_value=True), \
                mock.patch.object(ref, "write_sidecar", side_effect=sidecar) as supplement, \
                contextlib.redirect_stdout(io.StringIO()):
            flags = ["--graph-directory", str(fixture.graphs), "--records-directory", str(fixture.records),
                     "--first-strict-growth", "--bridge-evidence"]
            self.assertEqual(NODES.main(flags), 0)
            supplement.assert_not_called()
            self.assertEqual(NODES.main([*flags, "--reference-validation"]), 1)
            supplement.assert_called_once()


if __name__ == "__main__":
    unittest.main()
