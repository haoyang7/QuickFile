"""Bounded, tool-reported +40 bridge evidence; never an ownership claim."""
import hashlib
import json
import re

from ax_probe_report import HEAP_TYPES, allocation_generation, allocation_history, heap_allocations
from ax_evidence_errors import EvidenceError, ExitUnconfirmed
from ax_parser_evidence import thread_register

PUBLIC_LIMIT = 32 * 1024
REASONS = ("not_ready", "input_invalid", "graph_changed", "trace_unavailable", "references_invalid",
           "candidate_limit", "ambiguous_bridge", "tool_budget", "tool_failed", "deadline",
           "process_exit_unconfirmed", "heap_unavailable", "history_unavailable", "allocation_unknown",
           "layout_unavailable", "layout_conflict", "slot_unreported")
STATES = ("complete", "spawn_failed", "timeout", "exit_failed", "output_invalid", "output_limit")
ADDRESS = r"0x[0-9a-fA-F]{1,16}"
OBJECT = r"<([^<>\n]+) (" + ADDRESS + r")> \[(\d{1,10})\]"


def initial_summary(frozen):
    from ax_frozen_nodes import encode_summary as encode_frozen
    return {"schema": 1, "status": "unavailable", "semantics": "tool-reported",
            "frozen_sha256": hashlib.sha256(encode_frozen(frozen)).hexdigest(),
            "baseline_graph_sha256": (frozen.get("baseline") or {}).get("graph_sha256"),
            "selected_graph_sha256": (frozen.get("selected") or {}).get("graph_sha256"),
            "original_tool_count": len(frozen.get("tools", [])), "omitted_sources": 0,
            "records": [], "heap_tool_index": None, "history_tool_indices": {"baseline": None, "selected": None},
            "tools": [], "process_cleanup_confirmed": True, "reasons": []}


def fail_closed(result, reason):
    if reason not in REASONS:
        raise ValueError("Invalid bridge failure reason")
    result["status"] = "partial"
    if reason not in result["reasons"]:
        result["reasons"].append(reason)
    return result


def empty_layout():
    return {"tool_index": None, "state": "unavailable", "type_bucket": None, "size": None}


def parse_layout(report, source, target, source_size):
    """Only CONTENTS contains outgoing slots. Missing contents is unknown."""
    if len(report) > 16 * 1024 * 1024 or not report.endswith("\n"):
        raise ValueError("Incomplete layout")
    lines = report.strip().splitlines()
    if not lines:
        raise ValueError("Missing layout")
    scan = re.fullmatch(r"SCANNING " + OBJECT, lines[0])
    if not scan or int(scan[2], 16) != source or int(scan[3]) != source_size:
        raise ValueError("Unbound layout")
    if sum(line.startswith("SCANNING ") for line in lines) != 1 or lines.count("CONTENTS:") != 1:
        raise ValueError("Missing contents")
    prefix = [line for line in lines[1:lines.index("CONTENTS:")] if line.strip()]
    header = re.fullmatch(r"REFERENCES TO THIS: (\d{1,10})", prefix[0]) if prefix else None
    if not header or len(prefix) - 1 != int(header[1]):
        raise ValueError("Incomplete incoming references")
    for line in prefix[1:]:
        thread = re.fullmatch(r" +(Thread .+)", line)
        if thread and thread_register(thread[1]) is not None:
            continue
        region = re.fullmatch(r" +Region ([^\r\n\t<>]{1,1024}?) (" + ADDRESS + r")(?: --> offset (\d{1,10}))?", line)
        if (region and region[1].strip() and region[1].isprintable()
                and not re.search(ADDRESS, region[1]) and int(region[2], 16) > 0
                and (region[3] is None or int(region[3]) <= 1_000_000_000)):
            continue
        incoming = re.fullmatch(r"\s+" + OBJECT + r"\s+\+(\d{1,10}):\s+(?:[A-Za-z_\[\] .]+\s+)?(" + ADDRESS + r")", line)
        if not incoming:
            raise ValueError("Unsupported incoming reference")
        _, address, size, offset, slot = incoming.groups()
        if int(offset) + 8 > int(size) or int(slot, 16) != int(address, 16) + int(offset):
            raise ValueError("Unbound incoming reference")
    content = lines[lines.index("CONTENTS:") + 1:]
    found = None
    offsets = set()
    for line in content:
        if not line.strip():
            continue
        row = re.fullmatch(r"\s+\+(\d{1,10}):\s+(" + ADDRESS + r") --> " + OBJECT, line)
        if not row:
            raise ValueError("Unsupported contents")
        offset, slot, description, address, size = row.groups()
        offset, size = int(offset), int(size)
        if offset in offsets or offset + 8 > source_size or int(slot, 16) != source + offset or not 0 < size <= 1_000_000_000:
            raise ValueError("Unbound slot")
        offsets.add(offset)
        if offset == 40:
            original = int(address, 16) == target
            if original and size != 48:
                raise ValueError("Resized target")
            found = {"state": "original_target_address" if original else "other_allocation",
                     "type_bucket": description if description in HEAP_TYPES else "unknown", "size": size}
    return found or {"state": "unreported", "type_bucket": None, "size": None}


def history_evidence(before, after, before_size, after_size):
    value = {"classification": "unknown", "before_size": before_size, "after_size": after_size,
             "before_allocs": None, "before_frees": None, "after_allocs": None, "after_frees": None}
    for prefix, events in (("before", before), ("after", after)):
        if events is not None:
            for kind, suffix in (("ALLOC", "allocs"), ("FREE", "frees")):
                value[prefix + "_" + suffix] = sum(count for (event, _), count in events.items() if event == kind)
    if before_size != 64 or before is None or after is None:
        return value
    # NoCompact histories must agree with both complete heap inventories.
    # Keep the size balance too: a FREE for another size cannot close this allocation.
    def live_balance(events):
        sizes = {size for _, size in events}
        return {size: events[("ALLOC", size)] - events[("FREE", size)] for size in sizes
                if events[("ALLOC", size)] != events[("FREE", size)]}
    if live_balance(before) != {64: 1} or live_balance(after) != ({after_size: 1} if after_size is not None else {}):
        return value
    if after_size is not None:
        generation = allocation_generation(before, after, before_size, after_size)
        if generation == "preexisting_nodes":
            value["classification"] = "same_generation"
        elif generation == "new_allocation_nodes":
            value["classification"] = "reused"
    elif before and after and before[("ALLOC", before_size)] and not before - after:
        added = after - before
        if added[("FREE", before_size)] and not any(kind == "ALLOC" for kind, _ in added):
            value["classification"] = "freed"
    return value


def _selected_targets(frozen, candidate):
    views = [view for view in frozen["references"]["views"] if view["candidate"] == candidate and
             view["checkpoint"] == "selected" and view["kind"] == "tree" and view["status"] == "complete"]
    return set(views[0]["nodes"]) if len(views) == 1 else None


def _bound(frozen, candidates, source, target):
    refs = frozen["references"]
    nodes = {node["id"]: node for node in refs["nodes"] if node["checkpoint"] == "baseline"}
    if source not in nodes or target not in nodes or nodes[source]["size"] != 64 or nodes[target]["size"] != 48:
        return False
    for candidate in candidates:
        targets = _selected_targets(frozen, candidate)
        if targets is None or target not in targets:
            return False
        views = [view for view in refs["views"] if view["candidate"] == candidate and
                 view["checkpoint"] == "baseline" and view["kind"] == "trace" and view["status"] == "complete"]
        if len(views) != 1 or not {source, target} <= set(views[0]["nodes"]):
            return False
        if not any(refs["edges"][index]["source"] == source and refs["edges"][index]["target"] == target
                   and refs["edges"][index]["checkpoint"] == "baseline"
                   and refs["edges"][index]["relation"] == "reverse_reference" for index in views[0]["edges"]):
            return False
    return True


def collect(*, frozen, traces, baseline_heap, before_graph, after_graph, tools, reference_ids):
    result = initial_summary(frozen)
    result["tools"] = tools.summary["tools"]
    if frozen.get("status") != "complete":
        return fail_closed(result, "not_ready")
    if frozen.get("selection") in ("no-strict-growth", "no-new-leak"):
        result["status"] = "not_needed"
        return result
    if frozen.get("selected") is None or baseline_heap is None:
        return fail_closed(result, "not_ready")
    result["status"] = "complete"
    bridges = {}
    for index, candidate in enumerate(frozen["nodes"]):
        if candidate["baseline_presence"] == "absent":
            continue
        graph = traces.get(index)
        if graph is None or "slots" not in graph:
            fail_closed(result, "trace_unavailable")
            continue
        for slot in graph["slots"]:
            source, target = slot["source"], slot["target"]
            if slot["offset"] != 40 or graph["members"][source]["size"] != 64 or graph["members"][target]["size"] != 48:
                continue
            targets = _selected_targets(frozen, index)
            if source not in reference_ids or target not in reference_ids or targets is None:
                fail_closed(result, "references_invalid")
                continue
            # Restrict structural matches to this candidate's reported leak tree.
            # Upstream objects with the same sizes/offset do not consume the budget.
            if reference_ids[target] not in targets:
                continue
            if not _bound(frozen, [index], reference_ids[source], reference_ids[target]):
                fail_closed(result, "references_invalid")
                continue
            bridges.setdefault(source, {}).setdefault(target, set()).add(index)
    selected = []
    for source, targets in sorted(bridges.items()):
        if len(targets) != 1:
            result["omitted_sources"] += 1
            fail_closed(result, "ambiguous_bridge")
            continue
        target, candidates = next(iter(targets.items()))
        if len(selected) == 2:
            result["omitted_sources"] += 1
            fail_closed(result, "candidate_limit")
            continue
        selected.append((source, target))
        result["records"].append({"candidate_indices": sorted(candidates), "source_reference_id": reference_ids[source],
                                  "target_reference_id": reference_ids[target], "offset": 40,
                                  "history": history_evidence(None, None, baseline_heap.get(source), None),
                                  "baseline": empty_layout(), "selected": empty_layout()})
    if frozen.get("omitted_candidates"):
        fail_closed(result, "candidate_limit")
    if not selected:
        if not result["reasons"]:
            result["status"] = "not_needed"
        return result
    if result["original_tool_count"] + len(result["tools"]) + 3 + 2 * len(selected) > 45:
        return fail_closed(result, "tool_budget")
    stopped = False

    def run(kind, checkpoint, args):
        nonlocal stopped
        if stopped:
            return None, None
        if result["original_tool_count"] + len(result["tools"]) >= 45 or len(result["tools"]) >= 7:
            fail_closed(result, "tool_budget")
            return None, None
        index = len(result["tools"])
        try:
            report = tools.run(kind, checkpoint, args)
        except ExitUnconfirmed:
            stopped = True
            result["process_cleanup_confirmed"] = False
            fail_closed(result, "process_exit_unconfirmed")
            report = None
        except EvidenceError as error:
            fail_closed(result, error.reason if error.reason in REASONS else "tool_failed")
            report = None
        except OSError:
            fail_closed(result, "tool_failed")
            report = None
        result["process_cleanup_confirmed"] = result["process_cleanup_confirmed"] and tools.summary["process_cleanup_confirmed"]
        return report, index if len(result["tools"]) > index else None

    report, result["heap_tool_index"] = run("heap", "selected", ["/usr/bin/heap", "--noContent", "--addresses", "all", str(after_graph)])
    after_heap = heap_allocations(report) if report is not None else None
    if after_heap is None:
        fail_closed(result, "heap_unavailable")
    histories = {}
    addresses = [source for source, _ in selected]
    for checkpoint, path in (("baseline", before_graph), ("selected", after_graph)):
        report, result["history_tool_indices"][checkpoint] = run("history", checkpoint, ["/usr/bin/malloc_history", str(path), *map(hex, addresses)])
        histories[checkpoint] = allocation_history(report, addresses) if report is not None else None
        if histories[checkpoint] is None:
            fail_closed(result, "history_unavailable")
    for (source, target), record in zip(selected, result["records"]):
        before = histories["baseline"]
        after = histories["selected"]
        # An absent selected heap is distinct from a verified absent allocation.
        record["history"] = history_evidence(before[source] if before is not None else None,
            after[source] if after is not None else None, baseline_heap.get(source),
            after_heap.get(source) if after_heap is not None else None)
        if after_heap is None:
            record["history"]["classification"] = "unknown"
        if record["history"]["classification"] == "unknown":
            fail_closed(result, "allocation_unknown")
        for checkpoint, path, inventory in (("baseline", before_graph, baseline_heap), ("selected", after_graph, after_heap)):
            layout = record[checkpoint]
            if checkpoint == "selected" and inventory is not None and source not in inventory:
                layout["state"] = "not_present"
                continue
            report, tool_index = run("layout", checkpoint, ["/usr/bin/leaks", "--noContent", "--nosources", "--debug=layout", f"--debug={hex(source)}", str(path)])
            layout["tool_index"] = tool_index
            try:
                if report is None or inventory is None or source not in inventory:
                    raise ValueError("Unavailable source")
                layout.update(parse_layout(report, source, target, inventory[source]))
            except ValueError:
                fail_closed(result, "layout_unavailable")
            if layout["state"] == "unreported":
                fail_closed(result, "slot_unreported")
            if checkpoint == "baseline" and layout["state"] == "other_allocation":
                fail_closed(result, "layout_conflict")
    return result


def validate_summary(value, frozen):
    """Validate the closed public vocabulary, source bindings and tool lineage."""
    def require(condition):
        if not condition:
            raise ValueError("Invalid bounded bridge evidence")

    def integer(item):
        return type(item) is int and 0 <= item <= 1_000_000_000

    expected = initial_summary(frozen)
    require(type(value) is dict and set(value) == set(expected))
    require(type(value["schema"]) is int and value["schema"] == 1 and value["semantics"] == "tool-reported")
    require(value["status"] in ("complete", "partial", "unavailable", "not_needed"))
    for field in ("frozen_sha256", "baseline_graph_sha256", "selected_graph_sha256", "original_tool_count"):
        require(value[field] == expected[field])
    for field in ("frozen_sha256", "baseline_graph_sha256", "selected_graph_sha256"):
        require(value[field] is None or type(value[field]) is str and re.fullmatch(r"[0-9a-f]{64}", value[field]) is not None)
    require(integer(value["original_tool_count"]) and value["original_tool_count"] <= 45)
    require(integer(value["omitted_sources"]) and value["omitted_sources"] <= 512)
    require(type(value["process_cleanup_confirmed"]) is bool)
    require(type(value["reasons"]) is list and len(value["reasons"]) == len(set(value["reasons"])) and all(reason in REASONS for reason in value["reasons"]))
    require(type(value["tools"]) is list and len(value["tools"]) <= 7 and len(value["tools"]) + value["original_tool_count"] <= 45)
    for tool in value["tools"]:
        require(type(tool) is dict and set(tool) == {"tool", "label", "status", "return_code", "cleanup_confirmed"})
        require(tool["tool"] in ("heap", "history", "layout") and tool["label"] in ("baseline", "selected") and tool["status"] in STATES)
        require(type(tool["cleanup_confirmed"]) is bool)
        require(tool["return_code"] is None or type(tool["return_code"]) is int and -255 <= tool["return_code"] <= 255)
        if tool["status"] == "complete":
            require(tool["return_code"] == 0 and tool["cleanup_confirmed"])
    require(value["process_cleanup_confirmed"] == all(tool["cleanup_confirmed"] for tool in value["tools"]))
    if not value["process_cleanup_confirmed"]:
        require("process_exit_unconfirmed" in value["reasons"] and value["status"] == "partial")
    used = []

    def binding(index, kind, checkpoint, complete=False):
        if index is None:
            require(not complete)
            return
        require(integer(index) and index < len(value["tools"]) and index not in used)
        used.append(index)
        tool = value["tools"][index]
        require(tool["tool"] == kind and tool["label"] == checkpoint)
        if complete:
            require(tool["status"] == "complete")

    require(type(value["history_tool_indices"]) is dict and set(value["history_tool_indices"]) == {"baseline", "selected"})
    binding(value["heap_tool_index"], "heap", "selected")
    for checkpoint in ("baseline", "selected"):
        binding(value["history_tool_indices"][checkpoint], "history", checkpoint)
    require(type(value["records"]) is list and len(value["records"]) <= 2)
    sources = set()
    for record in value["records"]:
        require(type(record) is dict and set(record) == {"candidate_indices", "source_reference_id", "target_reference_id", "offset", "history", "baseline", "selected"})
        require(integer(record["source_reference_id"]) and integer(record["target_reference_id"]) and type(record["offset"]) is int and record["offset"] == 40)
        require(record["source_reference_id"] not in sources)
        sources.add(record["source_reference_id"])
        candidates = record["candidate_indices"]
        require(type(candidates) is list and 0 < len(candidates) <= 16 and all(integer(index) and index < len(frozen["nodes"]) for index in candidates))
        require(candidates == sorted(set(candidates)))
        require(_bound(frozen, candidates, record["source_reference_id"], record["target_reference_id"]))
        history = record["history"]
        require(type(history) is dict and set(history) == set(history_evidence(None, None, None, None)))
        require(history["classification"] in ("same_generation", "reused", "freed", "unknown"))
        for field in set(history) - {"classification"}:
            require(history[field] is None or integer(history[field]))
        for prefix, checkpoint in (("before", "baseline"), ("after", "selected")):
            counts = [history[prefix + "_allocs"], history[prefix + "_frees"]]
            require((counts[0] is None) == (counts[1] is None))
            if counts[0] is not None:
                idx = value["history_tool_indices"][checkpoint]
                require(idx is not None and value["tools"][idx]["status"] == "complete")
        if history["classification"] != "unknown":
            require(value["heap_tool_index"] is not None and value["tools"][value["heap_tool_index"]]["status"] == "complete")
            require(history["before_size"] == 64 and all(history[field] is not None for field in ("before_allocs", "before_frees", "after_allocs", "after_frees")))
            require(history["before_allocs"] > 0 and history["after_allocs"] >= history["before_allocs"] and history["after_frees"] >= history["before_frees"])
            require(history["before_allocs"] - history["before_frees"] == 1)
            require(history["after_allocs"] - history["after_frees"] == (1 if history["after_size"] is not None else 0))
            if history["classification"] == "same_generation":
                require(history["after_size"] == 64 and history["before_allocs"] == history["after_allocs"] and history["before_frees"] == history["after_frees"])
            elif history["classification"] == "reused":
                require(history["after_size"] is not None and history["after_allocs"] > history["before_allocs"] and history["after_frees"] > history["before_frees"])
            else:
                require(history["after_size"] is None and history["after_allocs"] == history["before_allocs"] and history["after_frees"] > history["before_frees"])
        for checkpoint in ("baseline", "selected"):
            layout = record[checkpoint]
            require(type(layout) is dict and set(layout) == set(empty_layout()))
            require(layout["state"] in ("original_target_address", "other_allocation", "unreported", "unavailable", "not_present"))
            if layout["state"] == "not_present":
                require(checkpoint == "selected" and layout["tool_index"] is None and history["after_size"] is None)
                require(value["heap_tool_index"] is not None and value["tools"][value["heap_tool_index"]]["status"] == "complete" and "heap_unavailable" not in value["reasons"])
            else:
                binding(layout["tool_index"], "layout", checkpoint, layout["state"] != "unavailable")
            if layout["state"] in ("original_target_address", "other_allocation"):
                require(layout["type_bucket"] in (*HEAP_TYPES, "unknown") and integer(layout["size"]) and layout["size"] > 0)
                if layout["state"] == "original_target_address":
                    require(layout["size"] == 48)
            else:
                require(layout["type_bucket"] is None and layout["size"] is None)
            if checkpoint == "baseline" and layout["state"] == "other_allocation":
                require(value["status"] == "partial" and "layout_conflict" in value["reasons"])
    require(sorted(used) == list(range(len(value["tools"]))))
    if value["status"] == "complete":
        require(frozen["status"] == "complete" and frozen.get("selected") is not None and not value["reasons"] and value["omitted_sources"] == 0 and value["process_cleanup_confirmed"])
        require(all(tool["status"] == "complete" for tool in value["tools"]))
        require(all(record["history"]["classification"] != "unknown" and all(record[checkpoint]["state"] in ("original_target_address", "other_allocation", "not_present") for checkpoint in ("baseline", "selected")) for record in value["records"]))
        require(all(record["baseline"]["state"] == "original_target_address" for record in value["records"]))
    elif value["status"] == "not_needed":
        require(frozen["status"] == "complete" and not value["records"] and not value["tools"] and not value["reasons"] and value["omitted_sources"] == 0)
        if frozen["selection"] not in ("no-strict-growth", "no-new-leak"):
            require(frozen.get("selected") is not None and not frozen.get("omitted_candidates"))
            for index, candidate in enumerate(frozen["nodes"]):
                if candidate["baseline_presence"] != "absent":
                    require(any(view["candidate"] == index and view["checkpoint"] == "baseline" and view["kind"] == "trace" and view["status"] == "complete" for view in frozen["references"]["views"]))
    else:
        require(bool(value["reasons"]))
    require(len((json.dumps(value, separators=(",", ":")) + "\n").encode()) <= PUBLIC_LIMIT)


def encode_summary(value, frozen):
    validate_summary(value, frozen)
    return (json.dumps(value, separators=(",", ":")) + "\n").encode("utf-8")
