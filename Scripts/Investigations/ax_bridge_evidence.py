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
           "layout_unavailable", "layout_conflict", "slot_unreported", "syntax_truncated", "syntax_unreplayable")
STATES = ("complete", "spawn_failed", "timeout", "exit_failed", "output_invalid", "output_limit")
ADDRESS = r"0x[0-9a-fA-F]{1,16}"
OBJECT = r"<([^<>\n]+) (" + ADDRESS + r")> \[(\d{1,10})\]"


def initial_summary(frozen):
    from ax_frozen_nodes import encode_summary as encode_frozen
    return {"schema": 2, "status": "unavailable", "semantics": "tool-reported",
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
    return {"tool_index": None, "state": "unavailable", "type_bucket": None, "size": None,
            "parse_error": "not_attempted", "syntax": None}


LAYOUT_ERRORS = {
    message: message.lower().replace(" ", "_") for message in (
        "Incomplete layout", "Missing layout", "Unbound layout", "Missing contents",
        "Incomplete incoming references", "Unsupported incoming reference", "Unbound incoming reference",
        "Unsupported contents", "Unbound slot", "Resized target", "Unavailable source")}
PARSE_ERRORS = ("none", "not_attempted", "tool_unavailable", "other_parser_error", *LAYOUT_ERRORS.values())
SYNTAX_LIMIT = 4096
SYNTAX_LINES = 64
SYNTAX_TOKENS = 512
SYNTAX_WORDS = frozenset(("SCANNING", "REFERENCES", "TO", "THIS", "CONTENTS", "Thread", "Region", "Stack",
                          "offset", "capture", "__strong", "__weak", *(f"x{i}" for i in range(31))))
SYNTAX_PUNCT = frozenset("<>[]:+-$()")
SYNTAX_LEX = re.compile(r"[ \t]+|[<>\[\]:+\-$()]|[^ \t<>\[\]:+\-$()\x00-\x1f\x7f]+|[\x00-\x1f\x7f]")
SYNTAX_STRIDE = 1 << 40


def _stack_metadata(line):
    """The observed debug-layout allocation stack, not a reference edge."""
    if len(line.encode("utf-8")) > 65536 or not line.startswith("\tCall stack: "):
        return False
    frames = line[len("\tCall stack: "):].rstrip(" ").split(" | ")
    if not 1 <= len(frames) <= 256:
        return False
    for frame in frames:
        match = re.fullmatch(ADDRESS + r" \(([^()\r\n\t|]{1,1024})\) ([^\r\n\t|]{1,4096})", frame)
        if not match or not match[1].strip() or not match[2].strip() or not frame.isprintable():
            return False
    return True


def layout_syntax(report, source, target, source_size, tool_index, graph_sha256):
    """Opaque descriptions and identities; preserve only checked pointer arithmetic."""
    addresses, opaque = {}, {}

    def identity(table, key):
        if key not in table:
            table[key] = len(table) + 1
        return table[key]

    def private_tokens(text):
        pending = []
        for part in re.finditer(ADDRESS + r"|[\s\S]", text):
            raw = part[0]
            if re.fullmatch(ADDRESS, raw):
                token = ["zero", 0] if int(raw, 16) == 0 else ["address", identity(addresses, int(raw, 16))]
            elif raw in "<>":
                token = ["literal", raw]
            elif ord(raw) <= 32 or ord(raw) == 127:
                token = ["char", ord(raw)]
            elif raw in "\x85\u2028\u2029":
                token = ["boundary", 0]
            elif not raw.isprintable():
                token = ["nonprintable", 0]
            else:
                pending.append(raw)
                continue
            if pending:
                private = "".join(pending)
                yield ["opaque", identity(opaque, private), len(private)]
                pending.clear()
            yield token
        if pending:
            private = "".join(pending)
            yield ["opaque", identity(opaque, private), len(private)]

    doc = {"status": "complete", "tool_index": tool_index, "graph_sha256": graph_sha256,
           "source": [identity(addresses, source), source_size], "target": identity(addresses, target),
           "ends_newline": report.endswith("\n"), "lines": []}
    lines = report[:-1].split("\n") if doc["ends_newline"] else report.split("\n")
    total = 0
    for line in lines:
        stack_metadata = _stack_metadata(line)
        if len(doc["lines"]) >= SYNTAX_LINES or (len(line) > 16384 and not stack_metadata):
            doc["status"] = "truncated"
            break
        if stack_metadata:
            # Its private frames are outside the incoming/outgoing slot evidence.
            # Retain the line and its position, so misplaced/duplicate metadata still fails.
            doc["lines"].append([["stack_metadata", 0]])
            total += 1
            if total > SYNTAX_TOKENS or len(json.dumps(doc, separators=(",", ":")).encode()) > SYNTAX_LIMIT - 32:
                doc["lines"].pop()
                doc["status"] = "truncated"
                break
            continue
        replacements, numbers, slots, thread_numbers = {}, set(), {}, {}
        # Only structural numeric fields survive. All unrelated decimal text is opaque.
        header = re.fullmatch(r"REFERENCES TO THIS: (\d{1,10})", line)
        if header and int(header[1]) <= 1_000_000_000:
            numbers.add(header.span(1))
        for obj in re.finditer(OBJECT, line):
            replacements[obj.start(1)] = (obj.end(1), obj[1])
            if int(obj[3]) <= 1_000_000_000:
                numbers.add(obj.span(3))
        thread = re.fullmatch(r" +Thread ([0-9]{1,10}) +(.*?) +\$([^ ]+)(?: --> offset ([0-9]{1,10}))?", line)
        if thread:
            # Neither real thread numbers nor any part of its display name leaves the report.
            if int(thread[1]) <= 1_000_000_000:
                thread_numbers[thread.span(1)] = identity(opaque, ("thread", thread[1]))
            replacements[thread.start(2)] = (thread.end(2), thread[2])
            if thread[4] is not None and int(thread[4]) <= 1_000_000_000:
                numbers.add(thread.span(4))
        region = re.fullmatch(r" +Region (.+?) (" + ADDRESS + r")(?: --> offset (\d{1,10}))?", line)
        if region:
            replacements[region.start(1)] = (region.end(1), region[1])
            if region[3] is not None and int(region[3]) <= 1_000_000_000:
                numbers.add(region.span(3))
        outgoing = re.fullmatch(r"\s+\+(\d{1,10}):\s+(" + ADDRESS + r") --> .+", line)
        incoming = re.fullmatch(r"\s+" + OBJECT + r"\s+\+(\d{1,10}):\s+(?:[A-Za-z_\[\] .]+\s+)?(" + ADDRESS + r")", line)
        for match, group in ((outgoing, 1), (incoming, 4)):
            if match and int(match[group]) <= 1_000_000_000:
                numbers.add(match.span(group))
        if outgoing and int(outgoing[1]) <= 1_000_000_000 and int(outgoing[2], 16) == source + int(outgoing[1]):
            slots[outgoing.span(2)] = ["slot", identity(addresses, source), int(outgoing[1])]
        if incoming and int(incoming[4]) <= 1_000_000_000 and int(incoming[5], 16) == int(incoming[2], 16) + int(incoming[4]):
            base = int(incoming[2], 16)
            slots[incoming.span(5)] = ["slot", identity(addresses, base) if base else 0, int(incoming[4])]
        tokens, position = [], 0
        while position < len(line):
            if position in replacements:
                end, text = replacements[position]
                if text:
                    # Retain rejection-relevant structure, never private display text.
                    tokens.extend(private_tokens(text))
                position = end
                continue
            match = SYNTAX_LEX.match(line, position)
            raw = match[0]
            if match.span() in slots:
                token = slots[match.span()]
            elif re.fullmatch(ADDRESS, raw):
                token = ["zero", 0] if int(raw, 16) == 0 else ["address", identity(addresses, int(raw, 16))]
            elif match.span() in thread_numbers:
                token = ["number", thread_numbers[match.span()]]
            elif match.span() in numbers:
                token = ["number", int(raw)]
            elif raw in SYNTAX_WORDS or raw in SYNTAX_PUNCT:
                token = ["literal", raw]
            elif set(raw) <= {" ", "\t"}:
                tokens.extend(["char", ord(char)] for char in raw)
                position = match.end()
                continue
            elif len(raw) == 1 and (ord(raw) < 32 or ord(raw) == 127):
                token = ["char", ord(raw)]
            else:
                tokens.extend(private_tokens(raw))
                position = match.end()
                continue
            tokens.append(token)
            position = match.end()
        total += len(tokens)
        doc["lines"].append(tokens)
        if total > SYNTAX_TOKENS or len(json.dumps(doc, separators=(",", ":")).encode()) > SYNTAX_LIMIT - 32:
            doc["lines"].pop()
            doc["status"] = "truncated"
            break
    if doc["status"] == "complete":
        def outcome(args):
            try:
                value = parse_layout(*args)
                # Descriptions deliberately lose type names; compare structural evidence.
                return "parsed", value["state"], value["size"]
            except ValueError as error:
                return "rejected", LAYOUT_ERRORS.get(str(error), "other_parser_error")
        if outcome((report, source, target, source_size)) != outcome(decode_layout_syntax(doc)):
            doc["status"] = "unreplayable"
    return doc


def decode_layout_syntax(doc):
    """Reconstruct anonymous syntax, never original descriptions or addresses."""
    def token_text(token):
        tag = token[0]
        if tag == "literal":
            return token[1]
        if tag == "number":
            return str(token[1])
        if tag == "char":
            return chr(token[1])
        if tag == "opaque":
            return "o" * token[2]
        if tag == "address":
            return hex(token[1] * SYNTAX_STRIDE)
        if tag in ("zero", "boundary", "nonprintable"):
            return {"zero": "0x0", "boundary": "\u2028", "nonprintable": "\u200d"}[tag]
        if tag == "stack_metadata":
            return "\tCall stack: 0x1 (opaque) opaque"
        return hex(token[1] * SYNTAX_STRIDE + token[2])
    report = "\n".join("".join(token_text(token) for token in line) for line in doc["lines"])
    if doc["ends_newline"]:
        report += "\n"
    return report, doc["source"][0] * SYNTAX_STRIDE, doc["target"] * SYNTAX_STRIDE, doc["source"][1]


def validate_layout_syntax(doc, tool_index, graph_sha256):
    def require(condition):
        if not condition:
            raise ValueError("Invalid anonymous layout syntax")
    def bounded(value, minimum=0, maximum=1_000_000_000):
        return type(value) is int and minimum <= value <= maximum
    require(type(doc) is dict and set(doc) == {"status", "tool_index", "graph_sha256", "source", "target", "ends_newline", "lines"})
    require(doc["status"] in ("complete", "truncated", "unreplayable") and bounded(doc["tool_index"], 0, 6) and doc["tool_index"] == tool_index and doc["graph_sha256"] == graph_sha256)
    require(type(doc["source"]) is list and len(doc["source"]) == 2 and type(doc["source"][0]) is int and doc["source"][0] == 1 and bounded(doc["source"][1], 1))
    require(type(doc["target"]) is int and doc["target"] == 2 and type(doc["ends_newline"]) is bool)
    require(type(doc["lines"]) is list and len(doc["lines"]) <= SYNTAX_LINES)
    count = 0
    for line in doc["lines"]:
        require(type(line) is list)
        count += len(line)
        for token in line:
            require(type(token) is list and len(token) in (2, 3))
            tag = token[0]
            if tag == "literal":
                require(len(token) == 2 and type(token[1]) is str and token[1] in SYNTAX_WORDS | SYNTAX_PUNCT)
            elif tag == "char":
                require(len(token) == 2 and bounded(token[1], 0, 127) and (token[1] <= 32 or token[1] == 127) and token[1] != 10)
            elif tag == "number":
                require(len(token) == 2 and bounded(token[1]))
            elif tag == "address":
                require(len(token) == 2 and bounded(token[1], 1, 1024))
            elif tag in ("zero", "boundary", "nonprintable", "stack_metadata"):
                require(len(token) == 2 and type(token[1]) is int and token[1] == 0)
            elif tag == "slot":
                require(len(token) == 3 and bounded(token[1], 0, 1024) and bounded(token[2]))
            else:
                require(tag == "opaque" and len(token) == 3 and bounded(token[1], 1, 1024) and bounded(token[2], 1, 16384))
    require(count <= SYNTAX_TOKENS and len(json.dumps(doc, separators=(",", ":")).encode()) <= SYNTAX_LIMIT)


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
    if prefix and _stack_metadata(prefix[0]):
        prefix = prefix[1:]
    header = re.fullmatch(r"REFERENCES TO THIS: (\d{1,10})", prefix[0]) if prefix else None
    if not header or len(prefix) - 1 != int(header[1]):
        raise ValueError("Incomplete incoming references")
    for line in prefix[1:]:
        thread = re.fullmatch(r" +(Thread .+)", line)
        register = thread_register(thread[1]) if thread else None
        if register is not None:
            if int(register[6] or "0") >= source_size:
                raise ValueError("Unbound incoming reference")
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
    if frozen.get("selection") in ("no-strict-growth", "no-new-leak", "live-no-growth"):
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
                layout["parse_error"] = "none"
            except ValueError as error:
                layout["parse_error"] = "tool_unavailable" if report is None else LAYOUT_ERRORS.get(str(error), "other_parser_error")
                fail_closed(result, "layout_unavailable")
            if report is not None:
                size = inventory.get(source, 64) if inventory is not None else 64
                layout["syntax"] = layout_syntax(report, source, target, size, tool_index,
                                                  result[checkpoint + "_graph_sha256"])
                if layout["syntax"]["status"] == "truncated":
                    fail_closed(result, "syntax_truncated")
                elif layout["syntax"]["status"] == "unreplayable":
                    fail_closed(result, "syntax_unreplayable")
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
    require(type(value["schema"]) is int and value["schema"] == 2 and value["semantics"] == "tool-reported")
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
            require(layout["parse_error"] in PARSE_ERRORS)
            syntax = layout["syntax"]
            if syntax is not None:
                require(integer(layout["tool_index"]) and layout["tool_index"] < len(value["tools"]) and value["tools"][layout["tool_index"]]["status"] == "complete")
                validate_layout_syntax(syntax, layout["tool_index"], value[checkpoint + "_graph_sha256"])
                expected_size = history["before_size" if checkpoint == "baseline" else "after_size"]
                require(syntax["source"][1] == (expected_size if expected_size is not None else 64))
                if syntax["status"] == "truncated":
                    require(value["status"] == "partial" and "syntax_truncated" in value["reasons"])
                elif syntax["status"] == "unreplayable":
                    require(value["status"] == "partial" and "syntax_unreplayable" in value["reasons"])
            if layout["tool_index"] is not None:
                require(integer(layout["tool_index"]) and layout["tool_index"] < len(value["tools"]))
                if value["tools"][layout["tool_index"]]["status"] == "complete":
                    require(syntax is not None and layout["parse_error"] not in ("not_attempted", "tool_unavailable"))
                else:
                    require(syntax is None and layout["state"] == "unavailable" and layout["parse_error"] == "tool_unavailable")
            if layout["state"] not in ("unavailable", "not_present"):
                require(layout["parse_error"] == "none" and syntax is not None)
            elif layout["state"] == "not_present":
                require(layout["parse_error"] == "not_attempted" and syntax is None)
            else:
                require(layout["parse_error"] != "none")
                if layout["parse_error"] not in ("not_attempted", "tool_unavailable"):
                    require(syntax is not None and "layout_unavailable" in value["reasons"] and value["status"] == "partial")
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
        if frozen["selection"] not in ("no-strict-growth", "no-new-leak", "live-no-growth"):
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
