"""Bounded frozen-checkpoint side evidence; address relations are not ownership.

Only the explicit full NoCompact protocol is accepted. Private tool output and
address mappings stay in an independently supervised process group and directory.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sys
import time

import ax_bridge_evidence as bridge_module
import ax_frozen_nodes as frozen_module
from ax_evidence_errors import EvidenceError, ExitUnconfirmed
from ax_probe_report import HEAP_LABELS, allocation_history, heap_allocations
from ax_process import run_owned

PUBLIC_LIMIT = 128 * 1024
TOOL_LIMIT = 56
SECONDS = 180
OBJECT_LIMIT = 12
ROOT_LIMIT = 4
UPSTREAM_LIMIT = 4
NODE_LIMIT = 256
EDGE_LIMIT = 512
HISTORY_SIZES = 8
PROTOCOL = {"schema": 1, "history_mode": "full-no-compact",
            "malloc_stack_logging": "unset", "malloc_stack_logging_no_compact": "1"}
ROLES = ("bridge_source", "bridge_target", "selected_xpc_root", "growth_candidate", "upstream_heap")
REASONS = ("input_invalid", "original_partial", "original_cleanup_unconfirmed", "graph_changed",
           "list_unavailable", "tree_unavailable", "heap_unavailable", "history_unavailable",
           "history_budget", "allocation_unknown", "trace_unavailable", "layout_unavailable",
           "context_unavailable", "root_limit", "candidate_limit", "upstream_limit", "reference_budget", "reference_conflict", "snapshot_conflict", "summary_budget",
           "tool_budget", "deadline", "tool_failed", "process_exit_unconfirmed", "private_cleanup_pending", "private_cleanup_failed", "worker_failed", "no_targets")
GENERATIONS = ("same_generation", "reused", "freed", "new_allocation", "absent_at_checkpoints", "unknown")
VIEW_STATES = ("complete", "not_present", "not_reported", "unknown", "budget_exceeded")


def encode(value):
    return (json.dumps(value, separators=(",", ":")) + "\n").encode("utf-8")


def digest(value):
    return hashlib.sha256(encode(value)).hexdigest()


def initial_summary(frozen, bridge):
    selected = frozen.get("selected_label") or HEAP_LABELS[-1]
    return {"schema": 1, "status": "unavailable", "semantics": "tool-reported-address-relations",
            "ownership": "not-established", "history_mode": "full-no-compact",
            "identity": "same-run-address", "incoming_scope": "trace-tree-reverse-references",
            "outgoing_scope": "leaked-tree-children-and-cycle-back",
            "allocation_stack": "unavailable", "allocation_clock": "unavailable",
            "frozen_sha256": digest(frozen), "bridge_sha256": digest(bridge),
            "selected_label": selected, "selection": "original-selected" if frozen.get("selected_label") else "last-checkpoint",
            "clock_availability": "unavailable", "checkpoint_windows": [], "checkpoints": [],
            "objects": [], "bridges": [], "selected_roots": [], "root_memberships": [],
            "references": {"nodes": [], "edges": [], "views": [], "differences": []},
            "omitted_roots": 0, "omitted_candidates": 0, "omitted_upstream": 0, "reasons": [], "tools": [],
            "worker_status": "not_started", "process_cleanup_confirmed": True}


def reason(value, name):
    if name not in value["reasons"]:
        value["reasons"].append(name)
    value["status"] = "partial"


def counts(events):
    if events is None:
        return None
    sizes = sorted({size for _, size in events})
    if len(sizes) > HISTORY_SIZES:
        return None
    return [{"size": size, "allocs": events[("ALLOC", size)], "frees": events[("FREE", size)]} for size in sizes]


def counter(rows):
    return Counter({(kind, row["size"]): row[field] for row in rows
                    for kind, field in (("ALLOC", "allocs"), ("FREE", "frees")) if row[field]})


def generation(before, after):
    if any(point["heap"] == "unknown" or point["history"] is None for point in (before, after)):
        return "unknown"
    old, new = counter(before["history"]), counter(after["history"])
    def balance(events):
        return {size: events[("ALLOC", size)] - events[("FREE", size)] for _, size in events
                if events[("ALLOC", size)] != events[("FREE", size)]}
    if any(balance(events) != ({point["size"]: 1} if point["heap"] == "present" else {})
           for point, events in ((before, old), (after, new))) or old - new:
        return "unknown"
    added = new - old
    allocs = sum(n for (kind, _), n in added.items() if kind == "ALLOC")
    frees = sum(n for (kind, _), n in added.items() if kind == "FREE")
    if before["heap"] == after["heap"] == "absent":
        return "absent_at_checkpoints"
    if before["heap"] == "absent" and after["heap"] == "present" and allocs:
        return "new_allocation"
    if before["heap"] == "present" and after["heap"] == "absent" and frees and not allocs:
        return "freed"
    if before["heap"] == after["heap"] == "present":
        if old == new and before["size"] == after["size"]:
            return "same_generation"
        if allocs and frees:
            return "reused"
    return "unknown"


def first_visible(timeline, field):
    values = [point[field] for point in timeline]
    if field == "heap":
        values = [None if item == "unknown" else item == "present" for item in values]
    elif field == "root_kind":
        values = [None if item == "unknown" else item in ("cycle", "leak") for item in values]
    index = next((i for i, item in enumerate(values) if item is True), None)
    if index is None:
        return {"state": "unknown" if None in values else "not_observed", "after": None, "through": None}
    if index == 0:
        return {"state": "at_baseline", "after": None, "through": HEAP_LABELS[0]}
    return {"state": "unknown" if None in values[:index] else "between_checkpoints",
            "after": None if None in values[:index] else HEAP_LABELS[index - 1], "through": HEAP_LABELS[index]}


def changes(timeline):
    result = []
    for before, after in zip(timeline, timeline[1:]):
        delta = None
        if before["history"] is not None and after["history"] is not None:
            old, new = counter(before["history"]), counter(after["history"])
            if not old - new:
                added = new - old
                delta = {"allocs": sum(n for (kind, _), n in added.items() if kind == "ALLOC"),
                         "frees": sum(n for (kind, _), n in added.items() if kind == "FREE")}
        result.append({"after": before["label"], "through": after["label"],
                       "generation": generation(before, after), "events": delta})
    return result


def windows(receipt):
    rows = receipt.get("checkpoint_windows")
    if rows is None:
        return []
    if not isinstance(rows, list) or len(rows) != len(HEAP_LABELS):
        raise ValueError("Invalid checkpoint windows")
    previous = 0
    for label, row in zip(HEAP_LABELS, rows):
        if (type(row) is not dict or set(row) != {"label", "phase", "start_monotonic", "end_monotonic"}
                or row["label"] != label or row["phase"] != label
                or any(type(row[key]) not in (int, float) or not math.isfinite(row[key]) or row[key] < 0
                       for key in ("start_monotonic", "end_monotonic"))
                or not previous <= row["start_monotonic"] <= row["end_monotonic"]):
            raise ValueError("Invalid checkpoint windows")
        previous = row["end_monotonic"]
    return rows


class Tools(frozen_module.Tools):
    """Executed only inside this sidecar's private run_owned process group."""
    def run(self, kind, label, command, allowed=(0,)):
        if not self.summary["process_cleanup_confirmed"]:
            raise ExitUnconfirmed()
        if len(self.summary["tools"]) >= TOOL_LIMIT:
            raise EvidenceError("tool_budget")
        return super().run(kind, label, command, allowed)


def edge_key(row):
    return (row["source"], row["target"], row["label"], row["relation"])


def differences(references):
    result = []
    for ident in sorted({view["object_id"] for view in references["views"]}):
        for kind in ("incoming", "outgoing"):
            pair = [next(view for view in references["views"] if
                         (view["object_id"], view["checkpoint"], view["kind"]) == (ident, label, kind))
                    for label in ("baseline", "selected")]
            row = {"object_id": ident, "kind": kind, "state": "unknown", "added": [], "removed": [], "retained": None}
            if all(view["state"] in ("complete", "not_present") for view in pair):
                old, new = ({edge_key(references["edges"][i]) for i in view["edges"]} for view in pair)
                row.update(state="complete", added=[list(key) for key in sorted(new - old)],
                           removed=[list(key) for key in sorted(old - new)], retained=len(old & new))
            result.append(row)
    return result


def root_membership(root, selected_tree, baseline_tree, baseline_heap, baseline_leaks, ident):
    """Whole selected subtree counts; intersection does not prove a closed cycle."""
    members = {key for key, obj in selected_tree["members"].items()
               if obj["root"] == selected_tree["members"][root["address"]]["root"]}
    cycles = {baseline_tree["members"][key]["root"] for key in members if baseline_tree is not None
              and key in baseline_tree["members"] and baseline_tree["roots"][baseline_tree["members"][key]["root"]]["summary"]["root_kind"] == "cycle"}
    cycle_members = sum(key in baseline_tree["members"] and baseline_tree["members"][key]["root"] in cycles
                        for key in members) if baseline_tree is not None else None
    present = len(members & baseline_heap.keys()) if baseline_heap is not None else 0
    return {"root_id": ident(root["address"]), "selected_members": len(members),
            "baseline_heap": {"present": present, "absent": len(members) - present if baseline_heap is not None else 0,
                              "unknown": len(members) if baseline_heap is None else 0},
            "baseline_leaked_members": len(members & baseline_leaks.keys()) if baseline_leaks is not None else None,
            "baseline_cycle_members": cycle_members, "baseline_cycle_roots": len(cycles) if baseline_tree is not None else None}


def collect(*, frozen, bridge, context, graphs, records, tools):
    """Read existing seven frozen checkpoints; never resample a live process."""
    value = initial_summary(frozen, bridge)
    value["tools"] = tools.summary["tools"]
    value["status"] = "complete"
    value["worker_status"] = "completed"
    def attempt(name, operation):
        try:
            return operation()
        except ExitUnconfirmed:
            value["process_cleanup_confirmed"] = False
            reason(value, "process_exit_unconfirmed")
            raise
        except EvidenceError as error:
            reason(value, error.reason if error.reason in REASONS else "tool_failed")
        except (OSError, ValueError, TypeError, KeyError, RecursionError):
            pass
        reason(value, name)
        return None
    def run(kind, label, args, allowed=(0,)):
        return tools.run(kind, label, args, allowed)
    maps, heaps, trees, histories = {}, {}, {}, {}
    paths = {label: graphs / (label + ".memgraph") for label in HEAP_LABELS}
    try:
        validate_inputs(frozen, bridge, records, graphs)
        receipt = frozen_module.read_json(records / "reference-validation-input.json")
        value["checkpoint_windows"] = windows(receipt)
        value["clock_availability"] = "checkpoint_windows" if value["checkpoint_windows"] else "unavailable"
        if frozen["status"] != "complete" or bridge["status"] not in ("complete", "not_needed"):
            reason(value, "original_partial")
        scans = frozen_module.read_json(records / "scans.json")
        for label, scan in zip(HEAP_LABELS, scans):
            graph = paths[label]
            point = {"label": label, "graph_sha256": frozen_module.graph_hash(graph),
                     "leak_nodes": scan["leak_nodes"], "leak_bytes": scan["leak_bytes"],
                     "list_status": "unknown", "tree_status": "unknown", "heap_status": "unknown", "history_status": "unknown",
                     "tools": {kind: None for kind in ("list", "tree", "heap", "history")}}
            value["checkpoints"].append(point)
            def listing():
                found, _ = frozen_module.parse_list(run("list", label, ["/usr/bin/leaks", "--noContent", "--nosources", "--list", str(graph)], (0, 1)))
                if (len(found), sum(found.values())) != (point["leak_nodes"], point["leak_bytes"]):
                    raise ValueError("Checkpoint mismatch")
                return found
            maps[label] = attempt("list_unavailable", listing)
            if maps[label] is not None:
                point["list_status"] = "complete"
                trees[label] = attempt("tree_unavailable", lambda: frozen_module.parse_tree_graph(
                    run("tree", label, ["/usr/bin/leaks", "--noContent", "--nosources", str(graph)], (0, 1)), maps[label]))
                if trees[label] is not None:
                    point["tree_status"] = "complete"
            else:
                trees[label] = None
            heaps[label] = attempt("heap_unavailable", lambda: heap_allocations(
                run("heap", label, ["/usr/bin/heap", "--noContent", "--addresses", "all", str(graph)])))
            if heaps[label] is None:
                reason(value, "heap_unavailable")
            elif maps[label] is not None and any(heaps[label].get(address) != size for address, size in maps[label].items()):
                heaps[label] = None
                reason(value, "snapshot_conflict")
            else:
                point["heap_status"] = "complete"
            for kind in ("list", "tree", "heap"):
                point["tools"][kind] = next((i for i, row in enumerate(value["tools"]) if row["tool"] == kind and row["label"] == label), None)
        selected_label = value["selected_label"]
        selected_tree = trees[selected_label]
        validate_context(context, frozen)
        ids = {address: ident for ident, address in context["addresses"]}
        next_id = context["next_id"]
        def ident(key, label=None):
            nonlocal next_id
            # Register ordinals are report-local. Region/metadata slot addresses
            # can share anonymous address identity, without allocation identity.
            key = (label, key) if isinstance(key, tuple) and key[0] == "thread-register" else key
            if key not in ids:
                ids[key] = next_id
                next_id += 1
            return ids[key]
        address_by_id = {number: address for address, number in ids.items()}
        subjects = {}
        def subject(address, role):
            if address not in subjects:
                subjects[address] = {"id": ident(address), "roles": []}
            if role not in subjects[address]["roles"]:
                subjects[address]["roles"].append(role)
        for record in bridge["records"]:
            source, target = (address_by_id.get(record[key]) for key in ("source_reference_id", "target_reference_id"))
            if source is None or target is None:
                reason(value, "context_unavailable")
                continue
            subject(source, "bridge_source")
            subject(target, "bridge_target")
        roots = [root for root in selected_tree["roots"] if root["summary"]["root_type"] == "NSXPCConnection"] if selected_tree is not None else []
        value["omitted_roots"] = max(0, len(roots) - ROOT_LIMIT)
        if value["omitted_roots"]:
            reason(value, "root_limit")
        for root in roots[:ROOT_LIMIT]:
            subject(root["address"], "selected_xpc_root")
            value["selected_roots"].append(ident(root["address"]))
            value["root_memberships"].append(root_membership(root, selected_tree, trees["baseline"], heaps["baseline"], maps["baseline"], ident))
        candidate_ids = {view["candidate"]: view["target"] for view in frozen["references"]["views"]
                         if view["checkpoint"] == "selected" and view["status"] == "complete"}
        value["omitted_candidates"] = frozen["omitted_candidates"]
        for candidate in frozen["nodes"]:
            address = address_by_id.get(candidate_ids.get(candidate["index"]))
            if address is None or address not in subjects and len(subjects) >= OBJECT_LIMIT - UPSTREAM_LIMIT:
                value["omitted_candidates"] += 1
            else:
                subject(address, "growth_candidate")
        if value["omitted_candidates"]:
            reason(value, "candidate_limit")

        refs = value["references"]
        raw_traces = {}
        slot_bindings = {}
        def publish(address, checkpoint, kind, graph, state, tool_index):
            view = {"object_id": ident(address), "checkpoint": checkpoint, "kind": kind,
                    "state": state, "root_count": graph.get("roots") if graph is not None else None,
                    "nodes": [], "edges": [], "tool_index": tool_index}
            refs["views"].append(view)
            if graph is None:
                return
            bindings = {(checkpoint, key): obj["slot_binding"] for key, obj in graph["members"].items()
                        if "slot_binding" in obj}
            if any(key in slot_bindings and slot_bindings[key] != binding for key, binding in bindings.items()):
                view.update(state="unknown", root_count=None)
                reason(value, "reference_conflict")
                return
            members = [{"id": ident(key, checkpoint), "checkpoint": checkpoint,
                        "type": obj["kind"] if obj["kind"] in frozen_module.REFERENCE_TYPES else "unknown",
                        "protocol": obj["protocol"], "size": obj["size"], "region": obj["region"]}
                       for key, obj in graph["members"].items()]
            edges = [{"checkpoint": checkpoint, "source": ident(edge["source"], checkpoint),
                      "target": ident(edge["target"], checkpoint), "label": edge["label"], "relation": edge["relation"]}
                     for edge in graph["edges"]]
            existing = {(node["id"], node["checkpoint"]): node for node in refs["nodes"]}
            for node in members:
                previous = existing.get((node["id"], node["checkpoint"]))
                if previous and (previous["size"] != node["size"] or previous["region"] != node["region"]
                    or previous["type"] not in ("unknown", node["type"]) and node["type"] != "unknown"
                    or previous["protocol"] not in ("none", "unknown", node["protocol"]) and node["protocol"] not in ("none", "unknown")):
                    view.update(state="unknown", root_count=None)
                    reason(value, "reference_conflict")
                    return
            extra_nodes = [node for node in members if (node["id"], node["checkpoint"]) not in existing]
            extra_edges = [edge for edge in edges if edge not in refs["edges"]]
            if len(refs["nodes"]) + len(extra_nodes) > NODE_LIMIT or len(refs["edges"]) + len(extra_edges) > EDGE_LIMIT:
                view.update(state="budget_exceeded", root_count=None)
                reason(value, "reference_budget")
                return
            slot_bindings.update(bindings)
            refs["nodes"].extend(extra_nodes)
            for node in members:
                previous = existing.get((node["id"], node["checkpoint"]))
                if previous:
                    if previous["type"] == "unknown": previous["type"] = node["type"]
                    if previous["protocol"] in ("none", "unknown"): previous["protocol"] = node["protocol"]
            refs["edges"].extend(extra_edges)
            view["nodes"] = sorted(node["id"] for node in members)
            view["edges"] = sorted(refs["edges"].index(edge) for edge in edges)
        def views(address):
            for checkpoint, label in (("baseline", "baseline"), ("selected", selected_label)):
                inventory, tree = heaps[label], trees[label]
                graph = None
                state = "unknown"
                trace_index = None
                if inventory is not None and address not in inventory:
                    state = "not_present"
                elif inventory is not None:
                    index = len(value["tools"])
                    graph = attempt("trace_unavailable", lambda: frozen_module.parse_trace_graph(
                        run("trace", label, ["/usr/bin/leaks", "--noContent", "--nosources", f"--traceTree={hex(address)}", str(paths[label])]),
                        address, inventory[address]))
                    trace_index = index if len(value["tools"]) > index else None
                    if graph is not None:
                        state = "complete"
                        raw_traces[(address, checkpoint)] = graph
                publish(address, checkpoint, "incoming", graph, state, trace_index)
                outgoing = None
                if state == "not_present":
                    out_state = "not_present"
                elif tree is None:
                    out_state = "unknown"
                elif address not in tree["members"]:
                    # A complete leaked tree does not enumerate all outgoing
                    # references of an allocated, non-leaked object.
                    out_state = "not_reported"
                else:
                    edges = [{"source": address, "target": key, "label": obj["edge"], "relation": "tree_child"}
                             for key, obj in tree["members"].items() if obj["parent"] == address]
                    edges += [{"source": edge["source"], "target": edge["target"], "label": edge["label"], "relation": "cycle_back"}
                              for edge in tree["back_edges"] if edge["source"] == address]
                    members = {key: tree["members"][key] for key in {address, *(edge["target"] for edge in edges)}}
                    outgoing = {"members": members, "edges": edges}
                    out_state = "complete"
                tree_index = value["checkpoints"][HEAP_LABELS.index(label)]["tools"]["tree"]
                publish(address, checkpoint, "outgoing", outgoing, out_state, tree_index)
        for address in list(subjects):
            views(address)
        upstream = set()
        for (_, checkpoint), graph in raw_traces.items():
            label = "baseline" if checkpoint == "baseline" else selected_label
            reached = {key for key, obj in graph["members"].items() if obj["region"] == "data"}
            while True:
                expanded = reached | {edge["target"] for edge in graph["edges"] if edge["source"] in reached}
                if expanded == reached:
                    break
                reached = expanded
            upstream.update(key for key, obj in graph["members"].items()
                            if type(key) is int and key not in subjects and heaps[label] is not None and key in heaps[label]
                            and (key in reached or obj["kind"] == "__NSMallocBlock__"))
        value["omitted_upstream"] = max(0, len(upstream) - UPSTREAM_LIMIT)
        if value["omitted_upstream"]:
            reason(value, "upstream_limit")
        for address in sorted(upstream)[:UPSTREAM_LIMIT]:
            subject(address, "upstream_heap")
            views(address)
        addresses = sorted(subjects)
        if not addresses:
            reason(value, "no_targets")
        for point in value["checkpoints"]:
            label = point["label"]
            histories[label] = attempt("history_unavailable", lambda: allocation_history(
                run("history", label, ["/usr/bin/malloc_history", str(paths[label]), *(hex(address) for address in addresses)]), addresses)) if addresses else {}
            if histories[label] is None:
                reason(value, "history_unavailable")
            elif addresses:
                point["history_status"] = "complete"
            point["tools"]["history"] = next((i for i, row in enumerate(value["tools"]) if row["tool"] == "history" and row["label"] == label), None)
        for address, obj in subjects.items():
            timeline = []
            for label in HEAP_LABELS:
                inventory, tree = heaps[label], trees[label]
                history = counts(histories[label][address]) if histories[label] is not None else None
                if histories[label] is not None and history is None:
                    reason(value, "history_budget")
                root = next((root for root in tree["roots"] if root["address"] == address), None) if tree is not None else None
                member = tree["members"].get(address) if tree is not None else None
                timeline.append({"label": label, "heap": "unknown" if inventory is None else "present" if address in inventory else "absent",
                    "size": inventory.get(address) if inventory is not None else None,
                    "leaked": address in maps[label] if maps[label] is not None else None,
                    "root_kind": "unknown" if tree is None else root["summary"]["root_kind"] if root else "none",
                    "type": member["kind"] if member and member["kind"] in frozen_module.REFERENCE_TYPES else "unknown",
                    "protocol": member["protocol"] if member else "unknown", "history": history})
            obj.update(timeline=timeline, generations=changes(timeline),
                       baseline_to_selected=generation(timeline[0], timeline[HEAP_LABELS.index(selected_label)]),
                       first_visible={field: first_visible(timeline, field) for field in ("heap", "leaked", "root_kind")})
            if obj["baseline_to_selected"] == "unknown" or any(row["generation"] == "unknown" for row in obj["generations"]):
                reason(value, "allocation_unknown")
            value["objects"].append(obj)
        for record in bridge["records"]:
            source, target = (address_by_id.get(record[key]) for key in ("source_reference_id", "target_reference_id"))
            if source not in subjects or target not in subjects:
                continue
            pair = {"source": ident(source), "target": ident(target), "offset": 40, "layouts": []}
            for checkpoint, label in (("baseline", "baseline"), ("selected", selected_label)):
                inventory = heaps[label]
                layout = {"checkpoint": checkpoint, "state": "unknown", "type": None, "size": None, "tool_index": None}
                if inventory is not None and source not in inventory:
                    layout["state"] = "source_absent"
                elif inventory is not None:
                    index = len(value["tools"])
                    parsed = attempt("layout_unavailable", lambda: bridge_module.parse_layout(
                        run("layout", label, ["/usr/bin/leaks", "--noContent", "--nosources", "--debug=layout", f"--debug={hex(source)}", str(paths[label])]),
                        source, target, inventory[source]))
                    layout["tool_index"] = index if len(value["tools"]) > index else None
                    if parsed is not None:
                        layout.update(state=parsed["state"], type=parsed["type_bucket"], size=parsed["size"])
                        if parsed["state"] == "unreported":
                            reason(value, "layout_unavailable")
                pair["layouts"].append(layout)
            value["bridges"].append(pair)
        refs["differences"] = differences(refs)
        if any(view["state"] in ("unknown", "not_reported", "budget_exceeded") for view in refs["views"]):
            reason(value, "trace_unavailable")
        if any(frozen_module.graph_hash(paths[row["label"]]) != row["graph_sha256"] for row in value["checkpoints"]):
            reason(value, "graph_changed")
    except ExitUnconfirmed:
        value.update(objects=[], bridges=[], selected_roots=[], root_memberships=[], references={"nodes": [], "edges": [], "views": [], "differences": []})
    except EvidenceError as error:
        reason(value, error.reason if error.reason in REASONS else "input_invalid")
        value.update(checkpoints=[], objects=[], bridges=[], selected_roots=[], root_memberships=[], references={"nodes": [], "edges": [], "views": [], "differences": []})
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        reason(value, "input_invalid")
        value.update(objects=[], bridges=[], selected_roots=[], root_memberships=[], references={"nodes": [], "edges": [], "views": [], "differences": []})
    value["process_cleanup_confirmed"] &= tools.summary["process_cleanup_confirmed"]
    # An interrupted child can abort in the middle of a checkpoint. Bind the
    # already completed calls even when the normal checkpoint tail was skipped.
    for point in value["checkpoints"]:
        for kind in point["tools"]:
            point["tools"][kind] = next((i for i, row in enumerate(value["tools"])
                if row["tool"] == kind and row["label"] == point["label"]), None)
    if not value["process_cleanup_confirmed"]:
        reason(value, "process_exit_unconfirmed")
    if len(encode(value)) > PUBLIC_LIMIT:
        value.update(objects=[], bridges=[], selected_roots=[], root_memberships=[], references={"nodes": [], "edges": [], "views": [], "differences": []})
        reason(value, "summary_budget")
    return value


def validate_inputs(frozen, bridge, records, graphs=None):
    frozen_module.validate_summary(frozen)
    bridge_module.validate_summary(bridge, frozen)
    if frozen["schema"] != 2:
        raise EvidenceError("input_invalid")
    cleanup = frozen_module.read_json(records / "process-cleanup.json")
    if (cleanup.get("processes_exited") is not True or cleanup.get("errors") != []
            or any(type(cleanup.get(role)) is not dict or cleanup[role].get("exited") is not True
                   or cleanup[role].get("errors") != [] for role in ("host", "reader"))
            or not frozen["process_cleanup_confirmed"] or not bridge["process_cleanup_confirmed"]
            or any(not tool["cleanup_confirmed"] for tool in [*frozen["tools"], *bridge["tools"]])):
        raise EvidenceError("original_cleanup_unconfirmed")
    receipt = frozen_module.read_json(records / "reference-validation-input.json")
    if any(type(receipt.get(key)) is not type(expected) or receipt[key] != expected for key, expected in PROTOCOL.items()):
        raise EvidenceError("input_invalid")
    windows(receipt)
    fixture = frozen_module.read_json(records / "result.json")
    if fixture.get("scan_mode") != "diagnostic" or fixture.get("live_attribution"):
        raise EvidenceError("input_invalid")
    scans = frozen_module.read_json(records / "scans.json")
    if type(scans) is not list or len(scans) != len(HEAP_LABELS):
        raise EvidenceError("input_invalid")
    for label, scan in zip(HEAP_LABELS, scans):
        if (scan.get("label") != label or any(not frozen_module.integer(scan.get(key)) for key in ("leak_nodes", "leak_bytes"))
                or type(scan.get("exit_code")) is not int or scan["exit_code"] not in (0, 1)):
            raise EvidenceError("input_invalid")
    if graphs is not None:
        for label, point in (("baseline", frozen["baseline"]), (frozen.get("selected_label"), frozen["selected"])):
            if point is not None and frozen_module.graph_hash(graphs / (label + ".memgraph")) != point["graph_sha256"]:
                raise EvidenceError("graph_changed")


def validate_context(context, frozen):
    if (type(context) is not dict or set(context) != {"frozen_sha256", "addresses", "next_id"}
            or context["frozen_sha256"] != digest(frozen) or type(context["addresses"]) is not list
            or len(context["addresses"]) > 200000 or not frozen_module.integer(context["next_id"])):
        raise ValueError("Invalid private context")
    numbers, addresses = set(), set()
    for row in context["addresses"]:
        if (type(row) is not list or len(row) != 2 or not frozen_module.integer(row[0]) or row[0] >= context["next_id"]
                or type(row[1]) is not int or not 0 < row[1] < 2 ** 64 or row[0] in numbers or row[1] in addresses):
            raise ValueError("Invalid private context")
        numbers.add(row[0]); addresses.add(row[1])


def validate_summary(value, frozen, bridge, graph_hashes=None):
    """Independent closed-schema gate; no private output or ownership claims."""
    def require(ok):
        if not ok:
            raise ValueError("Invalid reference validation summary")
    integer = frozen_module.integer
    frozen_module.validate_summary(frozen)
    bridge_module.validate_summary(bridge, frozen)
    expected = initial_summary(frozen, bridge)
    require(type(value) is dict and set(value) == set(expected))
    for key in ("schema", "semantics", "ownership", "history_mode", "identity", "incoming_scope", "outgoing_scope", "allocation_stack", "allocation_clock",
                "frozen_sha256", "bridge_sha256", "selected_label", "selection"):
        require(type(value[key]) is type(expected[key]) and value[key] == expected[key])
    require(value["status"] in ("complete", "partial", "unavailable"))
    require(type(value["process_cleanup_confirmed"]) is bool)
    require(value["worker_status"] in ("not_started", "completed", "timeout", "start_failed", "protocol_failed"))
    require(type(value["reasons"]) is list and len(value["reasons"]) == len(set(value["reasons"])))
    require(all(item in REASONS for item in value["reasons"]))
    require(value["status"] == "complete" if not value["reasons"] else value["status"] != "complete")
    require(type(value["checkpoint_windows"]) is list)
    require(windows({"checkpoint_windows": value["checkpoint_windows"]}) == value["checkpoint_windows"] if value["checkpoint_windows"] else True)
    require(value["clock_availability"] == ("checkpoint_windows" if value["checkpoint_windows"] else "unavailable"))
    for key, limit_reason in (("omitted_roots", "root_limit"), ("omitted_candidates", "candidate_limit"), ("omitted_upstream", "upstream_limit")):
        require(integer(value[key]))
        if value[key]: require(limit_reason in value["reasons"])
    require(type(value["tools"]) is list and len(value["tools"]) <= TOOL_LIMIT)
    for tool in value["tools"]:
        require(type(tool) is dict and set(tool) == {"tool", "label", "status", "return_code", "cleanup_confirmed"})
        require(tool["tool"] in ("list", "tree", "heap", "history", "trace", "layout") and tool["label"] in HEAP_LABELS)
        require(tool["status"] in frozen_module.TOOL_STATES and type(tool["cleanup_confirmed"]) is bool)
        require(tool["return_code"] is None or type(tool["return_code"]) is int and -255 <= tool["return_code"] <= 255)
        if tool["status"] == "complete":
            require(tool["cleanup_confirmed"] and tool["return_code"] in ((0, 1) if tool["tool"] in ("list", "tree") else (0,)))
    if value["process_cleanup_confirmed"]:
        require(all(tool["cleanup_confirmed"] for tool in value["tools"]))
    else:
        require("process_exit_unconfirmed" in value["reasons"] or "original_cleanup_unconfirmed" in value["reasons"])
    def binding(index, kind, label, complete=False):
        if index is None:
            require(not complete)
            return
        require(integer(index) and index < len(value["tools"]))
        tool = value["tools"][index]
        require((tool["tool"], tool["label"]) == (kind, label))
        if complete: require(tool["status"] == "complete")
    require(type(value["checkpoints"]) is list and len(value["checkpoints"]) <= len(HEAP_LABELS))
    for label, point in zip(HEAP_LABELS, value["checkpoints"]):
        require(type(point) is dict and set(point) == {"label", "graph_sha256", "leak_nodes", "leak_bytes", "list_status", "tree_status", "heap_status", "history_status", "tools"})
        require(point["label"] == label and integer(point["leak_nodes"]) and integer(point["leak_bytes"]))
        require(type(point["graph_sha256"]) is str and frozen_module.re.fullmatch(r"[0-9a-f]{64}", point["graph_sha256"]) is not None)
        if graph_hashes is not None: require(point["graph_sha256"] == graph_hashes[label])
        original = frozen["baseline"] if label == "baseline" else frozen["selected"] if label == frozen["selected_label"] else None
        if original is not None:
            require(all(point[key] == original[key] for key in ("graph_sha256", "leak_nodes", "leak_bytes")))
        require(type(point["tools"]) is dict and set(point["tools"]) == {"list", "tree", "heap", "history"})
        for kind in point["tools"]:
            require(point[kind + "_status"] in ("complete", "unknown"))
            binding(point["tools"][kind], kind, label, point[kind + "_status"] == "complete")
    require(type(value["objects"]) is list and len(value["objects"]) <= OBJECT_LIMIT)
    objects = {}
    for obj in value["objects"]:
        require(type(obj) is dict and set(obj) == {"id", "roles", "timeline", "generations", "baseline_to_selected", "first_visible"})
        require(integer(obj["id"]) and obj["id"] not in objects)
        objects[obj["id"]] = obj
        require(type(obj["roles"]) is list and 0 < len(obj["roles"]) == len(set(obj["roles"])) <= len(ROLES))
        require(all(role in ROLES for role in obj["roles"]))
        require(type(obj["timeline"]) is list and len(obj["timeline"]) == len(value["checkpoints"]) == len(HEAP_LABELS))
        for label, row, point in zip(HEAP_LABELS, obj["timeline"], value["checkpoints"]):
            require(type(row) is dict and set(row) == {"label", "heap", "size", "leaked", "root_kind", "type", "protocol", "history"})
            require(row["label"] == label and row["heap"] in ("present", "absent", "unknown"))
            require(row["heap"] != "unknown" if point["heap_status"] == "complete" else row["heap"] == "unknown")
            require(integer(row["size"]) and row["size"] > 0 if row["heap"] == "present" else row["size"] is None)
            require(type(row["leaked"]) is bool if point["list_status"] == "complete" else row["leaked"] is None)
            require(row["root_kind"] in ("none", "cycle", "leak") if point["tree_status"] == "complete" else row["root_kind"] == "unknown")
            require(row["type"] in frozen_module.REFERENCE_TYPES and row["protocol"] in frozen_module.REFERENCE_PROTOCOLS)
            if row["history"] is not None:
                require(point["history_status"] == "complete" and type(row["history"]) is list and len(row["history"]) <= HISTORY_SIZES)
                sizes = []
                for item in row["history"]:
                    require(type(item) is dict and set(item) == {"size", "allocs", "frees"})
                    require(all(integer(item[key]) for key in item) and item["size"] > 0)
                    sizes.append(item["size"])
                require(sizes == sorted(set(sizes)))
        require(obj["generations"] == changes(obj["timeline"]))
        require(obj["baseline_to_selected"] == generation(obj["timeline"][0], obj["timeline"][HEAP_LABELS.index(value["selected_label"])]))
        require(obj["first_visible"] == {field: first_visible(obj["timeline"], field) for field in ("heap", "leaked", "root_kind")})
        if obj["baseline_to_selected"] == "unknown" or any(row["generation"] == "unknown" for row in obj["generations"]):
            require("allocation_unknown" in value["reasons"])
    require(type(value["selected_roots"]) is list and len(value["selected_roots"]) <= ROOT_LIMIT)
    require(len(set(value["selected_roots"])) == len(value["selected_roots"]))
    require(set(value["selected_roots"]) == {obj["id"] for obj in value["objects"] if "selected_xpc_root" in obj["roles"]})
    for ident in value["selected_roots"]:
        row = objects[ident]["timeline"][HEAP_LABELS.index(value["selected_label"])]
        require(row["type"] == "NSXPCConnection" and row["root_kind"] in ("cycle", "leak"))
    require(type(value["root_memberships"]) is list and len(value["root_memberships"]) == len(value["selected_roots"]))
    for ident, membership in zip(value["selected_roots"], value["root_memberships"]):
        require(type(membership) is dict and set(membership) == {"root_id", "selected_members", "baseline_heap", "baseline_leaked_members", "baseline_cycle_members", "baseline_cycle_roots"})
        require(membership["root_id"] == ident and integer(membership["selected_members"]) and membership["selected_members"] > 0)
        require(type(membership["baseline_heap"]) is dict and set(membership["baseline_heap"]) == {"present", "absent", "unknown"})
        require(all(integer(count) for count in membership["baseline_heap"].values()) and sum(membership["baseline_heap"].values()) == membership["selected_members"])
        baseline = value["checkpoints"][0]
        require(membership["baseline_heap"]["unknown"] == (0 if baseline["heap_status"] == "complete" else membership["selected_members"]))
        for key in ("baseline_leaked_members", "baseline_cycle_members", "baseline_cycle_roots"):
            require(membership[key] is None or integer(membership[key]) and membership[key] <= membership["selected_members"])
        if membership["baseline_cycle_roots"] is not None:
            require(membership["baseline_cycle_members"] is not None and membership["baseline_cycle_roots"] <= membership["baseline_cycle_members"])
        require((membership["baseline_leaked_members"] is not None) == (baseline["list_status"] == "complete"))
        require(all((membership[key] is not None) == (baseline["tree_status"] == "complete") for key in ("baseline_cycle_members", "baseline_cycle_roots")))
    candidate_ids = {view["target"] for view in frozen["references"]["views"] if view["checkpoint"] == "selected" and view["status"] == "complete"}
    included_candidates = {obj["id"] for obj in value["objects"] if "growth_candidate" in obj["roles"]}
    require(included_candidates <= candidate_ids)
    if value["objects"]:
        require(len(included_candidates) + value["omitted_candidates"] == frozen["candidate_count"])
    require(type(value["bridges"]) is list and len(value["bridges"]) <= 2)
    for pair in value["bridges"]:
        require(type(pair) is dict and set(pair) == {"source", "target", "offset", "layouts"})
        require(any((row["source_reference_id"], row["target_reference_id"], row["offset"]) == (pair["source"], pair["target"], pair["offset"]) for row in bridge["records"]))
        for role in ("source", "target"):
            require(pair[role] in objects and "bridge_" + role in objects[pair[role]]["roles"])
        require(type(pair["layouts"]) is list and len(pair["layouts"]) == 2)
        for checkpoint, layout in zip(("baseline", "selected"), pair["layouts"]):
            require(type(layout) is dict and set(layout) == {"checkpoint", "state", "type", "size", "tool_index"})
            require(layout["checkpoint"] == checkpoint and layout["state"] in ("source_absent", "original_target_address", "other_allocation", "unreported", "unknown"))
            label = "baseline" if checkpoint == "baseline" else value["selected_label"]
            source = objects[pair["source"]]["timeline"][HEAP_LABELS.index(label)]
            if layout["state"] == "source_absent":
                require(source["heap"] == "absent" and layout["tool_index"] is None)
            else:
                binding(layout["tool_index"], "layout", label, layout["state"] != "unknown")
            if layout["state"] in ("original_target_address", "other_allocation"):
                require(layout["type"] in (*frozen_module.HEAP_TYPES, "unknown") and integer(layout["size"]) and layout["size"] > 0)
                if layout["state"] == "original_target_address": require(layout["size"] == 48)
            else: require(layout["type"] is None and layout["size"] is None)
    refs = value["references"]
    require(type(refs) is dict and set(refs) == {"nodes", "edges", "views", "differences"})
    require(type(refs["nodes"]) is list and len(refs["nodes"]) <= NODE_LIMIT)
    node_keys = set()
    for node in refs["nodes"]:
        require(type(node) is dict and set(node) == {"id", "checkpoint", "type", "protocol", "size", "region"})
        require(integer(node["id"]) and node["checkpoint"] in ("baseline", "selected") and integer(node["size"]))
        require(node["type"] in frozen_module.REFERENCE_TYPES and node["protocol"] in frozen_module.REFERENCE_PROTOCOLS and node["region"] in frozen_module.REFERENCE_REGIONS)
        require((node["checkpoint"], node["id"]) not in node_keys)
        node_keys.add((node["checkpoint"], node["id"]))
    require(type(refs["edges"]) is list and len(refs["edges"]) <= EDGE_LIMIT)
    for edge in refs["edges"]:
        require(type(edge) is dict and set(edge) == {"checkpoint", "source", "target", "label", "relation"})
        require(all((edge["checkpoint"], edge[key]) in node_keys for key in ("source", "target")))
        require(edge["label"] in frozen_module.REFERENCE_LABELS and edge["relation"] in ("tree_child", "cycle_back", "reverse_reference"))
    view_keys = set()
    require(type(refs["views"]) is list and len(refs["views"]) <= OBJECT_LIMIT * 4)
    for view in refs["views"]:
        require(type(view) is dict and set(view) == {"object_id", "checkpoint", "kind", "state", "root_count", "nodes", "edges", "tool_index"})
        key = (view["object_id"], view["checkpoint"], view["kind"])
        require(key not in view_keys and key[0] in objects and key[1] in ("baseline", "selected") and key[2] in ("incoming", "outgoing"))
        view_keys.add(key)
        require(view["state"] in VIEW_STATES and (view["root_count"] is None or integer(view["root_count"])))
        require(type(view["nodes"]) is list and view["nodes"] == sorted(set(view["nodes"])))
        require(type(view["edges"]) is list and view["edges"] == sorted(set(view["edges"])))
        require(all((view["checkpoint"], ident) in node_keys for ident in view["nodes"]))
        require(all(integer(i) and i < len(refs["edges"]) and refs["edges"][i]["checkpoint"] == view["checkpoint"]
                    and all(refs["edges"][i][field] in view["nodes"] for field in ("source", "target")) for i in view["edges"]))
        label = "baseline" if view["checkpoint"] == "baseline" else value["selected_label"]
        binding(view["tool_index"], "trace" if view["kind"] == "incoming" else "tree", label, view["state"] == "complete")
        if view["state"] == "complete":
            require(view["object_id"] in view["nodes"])
            require(integer(view["root_count"]) if view["kind"] == "incoming" else view["root_count"] is None)
            reached = {view["object_id"]}
            source, target = ("target", "source") if view["kind"] == "incoming" else ("source", "target")
            while True:
                expanded = reached | {refs["edges"][i][target] for i in view["edges"] if refs["edges"][i][source] in reached}
                if expanded == reached: break
                reached = expanded
            require(reached == set(view["nodes"]))
        else: require(not view["nodes"] and not view["edges"] and view["root_count"] is None)
        if view["state"] == "not_present": require(objects[key[0]]["timeline"][HEAP_LABELS.index(label)]["heap"] == "absent")
    require(view_keys == {(ident, checkpoint, kind) for ident in objects for checkpoint in ("baseline", "selected") for kind in ("incoming", "outgoing")})
    require(refs["differences"] == differences(refs))
    if value["status"] == "complete":
        require(value["worker_status"] == "completed" and value["process_cleanup_confirmed"] and bool(objects))
        require(len(value["checkpoints"]) == len(HEAP_LABELS) and frozen["status"] == "complete" and bridge["status"] in ("complete", "not_needed"))
        require(all(tool["status"] == "complete" for tool in value["tools"]))
        require(all(point[kind + "_status"] == "complete" for point in value["checkpoints"] for kind in ("list", "tree", "heap", "history")))
        require(all(view["state"] in ("complete", "not_present") for view in refs["views"]))
    require(len(encode(value)) <= PUBLIC_LIMIT)


def encode_summary(value, frozen, bridge):
    validate_summary(value, frozen, bridge)
    return encode(value)


def save_summary(path, value, frozen, bridge):
    payload = encode_summary(value, frozen, bridge)
    temporary = path.with_suffix(".tmp")
    if path.is_symlink() or temporary.is_symlink():
        raise ValueError("Invalid reference validation summary destination")
    try:
        temporary.write_bytes(payload)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def write_sidecar(frozen, context, graphs, records):
    """Called only after original summaries are saved; never edits those files."""
    value, bridge = None, None
    private = records / "reference-validation-private"
    created = launched = False
    try:
        bridge = frozen_module.read_json(records / "bridge-evidence.json", bridge_module.PUBLIC_LIMIT)
        value = initial_summary(frozen, bridge)
        if frozen_module.read_json(records / "frozen-nodes.json", frozen_module.PUBLIC_LIMIT) != frozen:
            raise EvidenceError("input_invalid")
        validate_inputs(frozen, bridge, records, graphs)
        private.mkdir(mode=0o700, exist_ok=False)
        created = True
        mapping = context.get("reference_ids", {})
        private_context = {"frozen_sha256": digest(frozen),
                           "addresses": [[number, key] for key, number in mapping.items() if type(key) is int],
                           "next_id": max(mapping.values(), default=-1) + 1}
        validate_context(private_context, frozen)
        (private / "context.json").write_bytes(encode(private_context))
        launched = True
        outcome = run_owned([sys.executable, str(Path(__file__).resolve()), "--worker",
            "--graph-directory", str(graphs), "--records-directory", str(records)],
            private / "worker.log", dict(os.environ), timeout=SECONDS + 5)
        if (private / "result.json").is_file():
            value = frozen_module.read_json(private / "result.json", PUBLIC_LIMIT)
            validate_summary(value, frozen, bridge)
        else:
            reason(value, "worker_failed")
        value["worker_status"] = outcome["status"]
        value["process_cleanup_confirmed"] = value["process_cleanup_confirmed"] and outcome["cleanup"]["complete"]
        if outcome["status"] != "completed" or outcome["command_return_code"] != 0:
            reason(value, "worker_failed")
        if not value["process_cleanup_confirmed"]:
            reason(value, "process_exit_unconfirmed")
    except EvidenceError as error:
        if value is not None:
            reason(value, error.reason if error.reason in REASONS else "input_invalid")
            if error.reason == "original_cleanup_unconfirmed": value["process_cleanup_confirmed"] = False
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        if bridge is not None:
            # Preserve actual cleanup uncertainty even if a worker artifact
            # cannot be decoded. No later tool may infer a safe launch from it.
            confirmed = value is not None and value.get("process_cleanup_confirmed") is True
            value = initial_summary(frozen, bridge)
            value["process_cleanup_confirmed"] = confirmed and (not launched or 'outcome' in locals() and outcome["cleanup"]["complete"])
            reason(value, "input_invalid")
            if not value["process_cleanup_confirmed"]: reason(value, "process_exit_unconfirmed")
    try:
        if value is None or bridge is None:
            return False
        target = records / "reference-validation.json"
        if created and value["process_cleanup_confirmed"]:
            # Commit the measured evidence before deleting its private inputs.
            # A failed final publication leaves this valid partial checkpoint,
            # never a complete summary that implies cleanup succeeded.
            status = value["status"]
            reason(value, "private_cleanup_pending")
            save_summary(target, value, frozen, bridge)
            value["reasons"].remove("private_cleanup_pending")
            value["status"] = status
            try:
                shutil.rmtree(private)
            except OSError:
                reason(value, "private_cleanup_failed")
        save_summary(target, value, frozen, bridge)
        return value["status"] == "complete" and value["process_cleanup_confirmed"]
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", action="store_true", required=True)
    parser.add_argument("--graph-directory", type=Path, required=True)
    parser.add_argument("--records-directory", type=Path, required=True)
    args = parser.parse_args(argv)
    records = args.records_directory
    try:
        frozen = frozen_module.read_json(records / "frozen-nodes.json", frozen_module.PUBLIC_LIMIT)
        bridge = frozen_module.read_json(records / "bridge-evidence.json", bridge_module.PUBLIC_LIMIT)
        private = records / "reference-validation-private"
        context = frozen_module.read_json(private / "context.json", frozen_module.RAW_LIMIT)
        validate_context(context, frozen)
        tools = Tools(private / "tools", {"tools": [], "process_cleanup_confirmed": True}, time.monotonic() + SECONDS)
        value = collect(frozen=frozen, bridge=bridge, context=context, graphs=args.graph_directory, records=records, tools=tools)
        payload = encode_summary(value, frozen, bridge)
        (private / "result.json").write_bytes(payload)
        return 0
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        # Private tool output and exception text are never printed.
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
